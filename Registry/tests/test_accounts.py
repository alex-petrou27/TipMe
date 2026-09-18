"""Custodial account signup/login and the ledger behind /v1/me."""
from tipme_registry import accounts
from tipme_registry.storage import InsufficientBalance


def _signup(client, email="alex@example.com", password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def test_signup_creates_a_session(client):
    response = _signup(client)
    assert response.status_code == 201
    body = response.json()
    assert body["email"] == "alex@example.com"
    assert body["session_token"]
    assert body["user_id"]


def test_signup_lowercases_email(client):
    response = _signup(client, email="Alex@Example.com")
    assert response.json()["email"] == "alex@example.com"


def test_signup_rejects_invalid_email(client):
    response = _signup(client, email="not-an-email")
    assert response.status_code == 400


def test_signup_rejects_short_password(client):
    response = _signup(client, password="short")
    assert response.status_code == 400


def test_signup_rejects_duplicate_email(client):
    _signup(client)
    response = _signup(client)
    assert response.status_code == 409


def test_login_with_correct_password(client):
    _signup(client, password="correct horse battery")
    response = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "correct horse battery",
    })
    assert response.status_code == 200
    assert response.json()["session_token"]


def test_login_wrong_password_is_rejected(client):
    _signup(client, password="correct horse battery")
    response = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "wrong password",
    })
    assert response.status_code == 401


def test_login_unknown_email_is_rejected_the_same_way(client):
    response = client.post("/v1/auth/login", json={
        "email": "nobody@example.com", "password": "whatever password",
    })
    assert response.status_code == 401


def test_me_requires_a_session(client):
    response = client.get("/v1/me")
    assert response.status_code == 401


def test_me_rejects_garbage_token(client):
    response = client.get("/v1/me", headers={"Authorization": "Bearer not-a-real-token"})
    assert response.status_code == 401


def test_me_reports_zero_balances_for_a_new_account(client):
    token = _signup(client).json()["session_token"]
    response = client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200
    balances = {entry["asset"]: entry["balance_minor"] for entry in response.json()["balances"]}
    assert balances == {"bitcoin": 0, "usdt": 0}


def test_logout_invalidates_the_session(client):
    token = _signup(client).json()["session_token"]
    logout = client.post("/v1/auth/logout", headers={"Authorization": f"Bearer {token}"})
    assert logout.status_code == 204

    response = client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


def test_logout_without_a_token_still_succeeds(client):
    response = client.post("/v1/auth/logout")
    assert response.status_code == 204


def test_adjust_balance_credits_and_debits(client):
    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    user_id = _signup(client).json()["user_id"]

    new_balance = storage.adjust_balance(user_id, "bitcoin", 1000, reason="tip_received")
    assert new_balance == 1000

    new_balance = storage.adjust_balance(user_id, "bitcoin", -400, reason="tip_sent")
    assert new_balance == 600

    balances = storage.get_balances(user_id)
    assert balances["bitcoin"] == 600


def test_adjust_balance_rejects_overdraft(client):
    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    user_id = _signup(client).json()["user_id"]

    try:
        storage.adjust_balance(user_id, "bitcoin", -1, reason="tip_sent")
        assert False, "expected InsufficientBalance"
    except InsufficientBalance:
        pass

    assert storage.get_balances(user_id).get("bitcoin", 0) == 0


def test_password_hash_round_trip():
    hashed = accounts.hash_password("correct horse battery")
    assert accounts.verify_password("correct horse battery", hashed)
    assert not accounts.verify_password("wrong password", hashed)


def test_password_hashes_are_salted_differently():
    assert accounts.hash_password("same password") != accounts.hash_password("same password")


# --------------------------------------------------------------------------
# Forgot / reset password
# --------------------------------------------------------------------------

def _request_reset_code(client, caplog, email="alex@example.com"):
    """No real email provider is configured in tests (or in dev -- see
    mailer.py), so the code the app would have received by email is read
    back out of the log line that stands in for sending it."""
    import logging
    with caplog.at_level(logging.WARNING, logger="tipme_registry.mailer"):
        response = client.post("/v1/auth/forgot-password", json={"email": email})
    assert response.status_code == 204
    for record in caplog.records:
        if "Password reset code for" in record.message:
            return record.message.split(": ")[1].split(" ")[0]
    return None


def test_forgot_password_is_204_for_a_real_account(client, caplog):
    _signup(client)
    code = _request_reset_code(client, caplog)
    assert code is not None


def test_forgot_password_is_204_for_an_unknown_email_too(client, caplog):
    """Same response either way -- this endpoint must not let a caller learn
    which emails have accounts."""
    import logging
    with caplog.at_level(logging.WARNING, logger="tipme_registry.mailer"):
        response = client.post("/v1/auth/forgot-password", json={"email": "nobody@example.com"})
    assert response.status_code == 204
    assert not any("Password reset code" in r.message for r in caplog.records)


def test_reset_password_with_a_valid_code(client, caplog):
    _signup(client, password="old password")
    code = _request_reset_code(client, caplog)

    response = client.post("/v1/auth/reset-password", json={
        "code": code, "new_password": "new password 123",
    })
    assert response.status_code == 200
    assert response.json()["session_token"]

    login = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "new password 123",
    })
    assert login.status_code == 200


def test_reset_password_code_is_single_use(client, caplog):
    _signup(client)
    code = _request_reset_code(client, caplog)

    first = client.post("/v1/auth/reset-password", json={"code": code, "new_password": "new password 123"})
    assert first.status_code == 200

    second = client.post("/v1/auth/reset-password", json={"code": code, "new_password": "another password"})
    assert second.status_code == 400


def test_reset_password_rejects_unknown_code(client):
    response = client.post("/v1/auth/reset-password", json={
        "code": "NOTREAL1", "new_password": "new password 123",
    })
    assert response.status_code == 400


def test_reset_password_invalidates_existing_sessions(client, caplog):
    old_token = _signup(client).json()["session_token"]
    code = _request_reset_code(client, caplog)
    client.post("/v1/auth/reset-password", json={"code": code, "new_password": "new password 123"})

    response = client.get("/v1/me", headers={"Authorization": f"Bearer {old_token}"})
    assert response.status_code == 401


# --------------------------------------------------------------------------
# Change password
# --------------------------------------------------------------------------

def test_change_password_with_correct_current_password(client):
    token = _signup(client, password="old password").json()["session_token"]
    response = client.post("/v1/auth/change-password",
                           headers={"Authorization": f"Bearer {token}"},
                           json={"current_password": "old password", "new_password": "new password 123"})
    assert response.status_code == 204

    login = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "new password 123",
    })
    assert login.status_code == 200


def test_change_password_rejects_wrong_current_password(client):
    token = _signup(client, password="old password").json()["session_token"]
    response = client.post("/v1/auth/change-password",
                           headers={"Authorization": f"Bearer {token}"},
                           json={"current_password": "wrong password", "new_password": "new password 123"})
    assert response.status_code == 403

    login = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "old password",
    })
    assert login.status_code == 200


def test_change_password_requires_a_session(client):
    response = client.post("/v1/auth/change-password",
                           json={"current_password": "x", "new_password": "new password 123"})
    assert response.status_code == 401


def test_change_password_keeps_the_current_session_but_logs_out_others(client):
    session_a = _signup(client, password="old password").json()["session_token"]
    session_b = client.post("/v1/auth/login", json={
        "email": "alex@example.com", "password": "old password",
    }).json()["session_token"]

    client.post("/v1/auth/change-password",
               headers={"Authorization": f"Bearer {session_a}"},
               json={"current_password": "old password", "new_password": "new password 123"})

    assert client.get("/v1/me", headers={"Authorization": f"Bearer {session_a}"}).status_code == 200
    assert client.get("/v1/me", headers={"Authorization": f"Bearer {session_b}"}).status_code == 401
