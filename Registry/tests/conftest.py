import os
import tempfile

import pytest
from fastapi.testclient import TestClient

from tipme_registry import signing


@pytest.fixture
def client(monkeypatch):
    private, public = signing.generate_keypair()
    db = tempfile.NamedTemporaryFile(suffix=".sqlite3", delete=False)
    db.close()

    monkeypatch.setenv("REGISTRY_SIGNING_PRIVATE_KEY", private)
    monkeypatch.setenv("REGISTRY_DATABASE_PATH", db.name)
    monkeypatch.setenv("REGISTRY_ADMIN_TOKEN", "test-admin-token")

    # The module caches settings, storage and the rate-limit window globally;
    # reset all three so tests do not leak state into each other.
    from tipme_registry import app as app_module
    app_module._settings = None
    app_module._storage = None
    app_module._registration_attempts.clear()

    test_client = TestClient(app_module.app)
    test_client.public_key = public
    yield test_client

    os.unlink(db.name)


@pytest.fixture
def registered(client):
    response = client.post("/v1/creators", json={
        "platform": "tiktok",
        "username": "creator",
        "lightning_address": "creator@getalby.com",
    })
    assert response.status_code == 201
    return response.json()


@pytest.fixture
def management_token(registered):
    """The secret issued on first claim, required to change the record."""
    return registered["management_token"]
