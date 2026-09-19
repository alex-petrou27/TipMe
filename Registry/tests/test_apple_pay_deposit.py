"""Dummy Apple Pay top-up: no processor, no rail, just a trusted credit to
the caller's USDT balance keyed on their own idempotency reference.
"""


def _signup(client, email, password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def test_apple_pay_deposit_credits_usdt_balance(client):
    user = _signup(client, "payer@example.com").json()

    response = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "apple-pay-txn-1"},
        headers=_headers(user["session_token"]),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "completed"
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["usdt"] == 500


def test_apple_pay_deposit_is_idempotent_on_reference(client):
    user = _signup(client, "payer@example.com").json()

    first = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "apple-pay-txn-1"},
        headers=_headers(user["session_token"]),
    )
    second = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "apple-pay-txn-1"},
        headers=_headers(user["session_token"]),
    )
    assert first.status_code == 200
    assert second.status_code == 200
    balances = {b["asset"]: b["balance_minor"] for b in second.json()["balances"]}
    assert balances["usdt"] == 500


def test_apple_pay_deposit_rejects_a_non_positive_amount(client):
    user = _signup(client, "payer@example.com").json()
    response = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 0, "reference": "apple-pay-txn-1"},
        headers=_headers(user["session_token"]),
    )
    assert response.status_code == 422


def test_apple_pay_deposit_requires_authentication(client):
    response = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "apple-pay-txn-1"},
    )
    assert response.status_code == 401


def test_apple_pay_deposit_reference_cannot_be_claimed_by_another_user(client):
    first_user = _signup(client, "payer@example.com").json()
    second_user = _signup(client, "other@example.com").json()

    client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "shared-reference"},
        headers=_headers(first_user["session_token"]),
    )
    response = client.post(
        "/v1/deposit/apple_pay",
        json={"amount_minor": 500, "reference": "shared-reference"},
        headers=_headers(second_user["session_token"]),
    )
    assert response.status_code == 404
