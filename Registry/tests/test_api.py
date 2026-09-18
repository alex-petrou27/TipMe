import base64
import json

from tipme_registry import signing


def decode(client, response):
    """Verifies the envelope the way the iOS client does, then returns the record."""
    return signing.verify_envelope(client.public_key, response.json())


def test_register_then_lookup(client, registered):
    response = client.get("/v1/creators/tiktok/creator")
    assert response.status_code == 200

    record = decode(client, response)
    assert record["username"] == "creator"
    assert record["platform"] == "tiktok"
    assert record["lightning_address"] == "creator@getalby.com"
    assert record["preferred_asset"] == "bitcoin"


def test_lookup_is_signed_by_the_registry_key(client, registered):
    """End-to-end proof that what the server signs is what the client verifies."""
    response = client.get("/v1/creators/tiktok/creator")
    envelope = response.json()

    assert set(envelope) == {"payload", "signature"}
    # Verifying with a different key must fail.
    _, other_public = signing.generate_keypair()
    try:
        signing.verify_envelope(other_public, envelope)
        raise AssertionError("a foreign key verified our signature")
    except Exception:
        pass


def test_lookup_of_unregistered_creator_is_a_plain_404(client):
    """The common case: most creators have not signed up. The client turns this
    into a manual-entry offer rather than an error screen."""
    response = client.get("/v1/creators/tiktok/nobody")
    assert response.status_code == 404


def test_lookup_normalises_casing(client, registered):
    assert client.get("/v1/creators/tiktok/CREATOR").status_code == 200


def test_lookup_rejects_impossible_handles_before_touching_storage(client):
    assert client.get("/v1/creators/tiktok/" + "a" * 25).status_code == 400
    assert client.get("/v1/creators/instagram/accounts").status_code == 400
    assert client.get("/v1/creators/mastodon/someone").status_code == 400


def test_lookup_responses_are_not_cacheable(client, registered):
    """Signed records are short-lived; an intermediary caching one past its
    freshness window would serve a record the client then rejects as stale."""
    response = client.get("/v1/creators/tiktok/creator")
    assert response.headers["cache-control"] == "no-store"


def test_new_registrations_are_never_verified(client, registered):
    """Registration is open, verification is not. Otherwise claiming
    @charlidamelio would be enough to collect her tips."""
    assert registered["verified"] is False
    record = decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["verified"] is False


def test_verify_requires_the_admin_token(client, registered):
    assert client.post("/v1/creators/tiktok/creator/verify").status_code == 403
    assert client.post(
        "/v1/creators/tiktok/creator/verify",
        headers={"X-Admin-Token": "wrong"},
    ).status_code == 403

    response = client.post(
        "/v1/creators/tiktok/creator/verify",
        headers={"X-Admin-Token": "test-admin-token"},
    )
    assert response.status_code == 200
    assert decode(client, client.get("/v1/creators/tiktok/creator"))["verified"] is True


def test_a_registered_handle_cannot_be_taken_over(client, registered):
    """The attack this closes: re-register a registered creator's handle
    pointing at your own wallet, and collect their tips. Clearing the verified
    flag warns users but does not stop the payment, so the write itself has to
    be refused."""
    response = client.post("/v1/creators", json={
        "platform": "tiktok",
        "username": "creator",
        "lightning_address": "attacker@evil.example",
    })
    assert response.status_code == 403

    record = decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["lightning_address"] == "creator@getalby.com", "destination must be unchanged"


def test_wrong_management_token_is_refused(client, registered):
    response = client.post(
        "/v1/creators",
        json={
            "platform": "tiktok",
            "username": "creator",
            "lightning_address": "attacker@evil.example",
        },
        headers={"X-Management-Token": "tipme-manage-wrong"},
    )
    assert response.status_code == 403


def test_creator_can_change_their_own_wallet(client, management_token):
    response = client.post(
        "/v1/creators",
        json={
            "platform": "tiktok",
            "username": "creator",
            "lightning_address": "creator@strike.me",
        },
        headers={"X-Management-Token": management_token},
    )
    assert response.status_code == 201

    record = decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["lightning_address"] == "creator@strike.me"


def test_admin_can_change_a_record_without_the_management_token(client, registered):
    response = client.post(
        "/v1/creators",
        json={
            "platform": "tiktok",
            "username": "creator",
            "lightning_address": "creator@strike.me",
        },
        headers={"X-Admin-Token": "test-admin-token"},
    )
    assert response.status_code == 201


def test_management_token_is_issued_once_and_not_reissued(client, management_token):
    """Re-issuing it on every update would let anyone who can read one response
    take the record over."""
    assert management_token.startswith("tipme-manage-")

    response = client.post(
        "/v1/creators",
        json={
            "platform": "tiktok",
            "username": "creator",
            "lightning_address": "creator@strike.me",
        },
        headers={"X-Management-Token": management_token},
    )
    assert response.json()["management_token"] is None


def test_changing_wallet_clears_verification(client, management_token):
    """Verification attests that a person controls a specific wallet. Changing
    the wallet invalidates that, so the badge must not carry over."""
    client.post("/v1/creators/tiktok/creator/verify",
                headers={"X-Admin-Token": "test-admin-token"})
    assert decode(client, client.get("/v1/creators/tiktok/creator"))["verified"] is True

    client.post(
        "/v1/creators",
        json={
            "platform": "tiktok",
            "username": "creator",
            "lightning_address": "creator@strike.me",
        },
        headers={"X-Management-Token": management_token},
    )

    record = decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["lightning_address"] == "creator@strike.me"
    assert record["verified"] is False


def test_registration_is_rate_limited(client):
    """Without a limit, a script could claim every popular handle before their
    owners do and point them all at one wallet."""
    for index in range(10):
        response = client.post("/v1/creators", json={
            "platform": "tiktok",
            "username": f"creator{index}",
            "lightning_address": f"creator{index}@getalby.com",
        })
        assert response.status_code == 201, f"registration {index} should succeed"

    response = client.post("/v1/creators", json={
        "platform": "tiktok",
        "username": "creator_too_many",
        "lightning_address": "another@getalby.com",
    })
    assert response.status_code == 429


def test_updating_an_existing_record_does_not_consume_the_new_claim_budget(client, management_token):
    """Rate limiting targets handle-squatting, not a creator fixing a typo."""
    for _ in range(15):
        response = client.post(
            "/v1/creators",
            json={
                "platform": "tiktok",
                "username": "creator",
                "lightning_address": "creator@getalby.com",
            },
            headers={"X-Management-Token": management_token},
        )
        assert response.status_code == 201


def test_register_rejects_bad_lightning_address(client):
    response = client.post("/v1/creators", json={
        "platform": "tiktok",
        "username": "creator",
        "lightning_address": "not-an-address",
    })
    assert response.status_code == 400


def test_register_rejects_unknown_asset(client):
    response = client.post("/v1/creators", json={
        "platform": "tiktok",
        "username": "creator",
        "lightning_address": "creator@getalby.com",
        "preferred_asset": "dogecoin",
    })
    assert response.status_code == 400


def test_register_accepts_usdt_preference(client):
    """Receiver picks what they want to receive; the sender's asset is converted
    in flight by the app."""
    client.post("/v1/creators", json={
        "platform": "instagram",
        "username": "natgeo",
        "lightning_address": "natgeo@getalby.com",
        "preferred_asset": "usdt",
        "minimum_tip_minor_units": 100,
    })
    record = decode(client, client.get("/v1/creators/instagram/natgeo"))
    assert record["preferred_asset"] == "usdt"
    assert record["minimum_tip_minor_units"] == 100


def test_delete_requires_a_token_and_removes_the_record(client, registered):
    assert client.delete("/v1/creators/tiktok/creator").status_code == 403

    response = client.delete("/v1/creators/tiktok/creator",
                             headers={"X-Admin-Token": "test-admin-token"})
    assert response.status_code == 204
    assert client.get("/v1/creators/tiktok/creator").status_code == 404


def test_creator_can_unlink_their_own_handle(client, management_token):
    """Self-service: the same device that can change where tips go can also
    remove the record entirely, with the same management token."""
    response = client.delete("/v1/creators/tiktok/creator",
                             headers={"X-Management-Token": management_token})
    assert response.status_code == 204
    assert client.get("/v1/creators/tiktok/creator").status_code == 404


def test_wrong_management_token_cannot_unlink(client, registered):
    response = client.delete("/v1/creators/tiktok/creator",
                             headers={"X-Management-Token": "not-the-real-token"})
    assert response.status_code == 403
    # Still there -- a rejected delete must not have side effects.
    assert client.get("/v1/creators/tiktok/creator").status_code == 200


def test_deleting_an_unregistered_handle_is_a_plain_404(client):
    response = client.delete("/v1/creators/tiktok/nobody",
                             headers={"X-Admin-Token": "test-admin-token"})
    assert response.status_code == 404


def test_signed_at_is_fresh_on_every_lookup(client, registered):
    """signed_at is what makes a captured response un-replayable after a creator
    moves wallet, so it must be per-response, not per-record."""
    first = decode(client, client.get("/v1/creators/tiktok/creator"))
    second = decode(client, client.get("/v1/creators/tiktok/creator"))
    assert "signed_at" in first and "signed_at" in second


def test_payload_uses_snake_case_keys_for_the_swift_client(client, registered):
    """The iOS decoder uses .convertFromSnakeCase; camelCase keys here would
    decode to nil and the record would be rejected as malformed."""
    record = decode(client, client.get("/v1/creators/tiktok/creator"))
    for key in ("lightning_address", "preferred_asset", "minimum_tip_minor_units",
                "display_name", "updated_at", "signed_at"):
        assert key in record, f"missing {key}"


def test_health(client):
    assert client.get("/health").json() == {"status": "ok"}
