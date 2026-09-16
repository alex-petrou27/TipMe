"""Creator confirm-screen photos: cosmetic, gated by the same management
token as any other change to a record, never touching the payment path."""
import io

JPEG_BYTES = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300030202020203020"
    "20203030304060404040405060505060706070707060706080809090a08080809"
    "090a0b0d0c0a0b0d0c0c0c0c0e0f100f0d0e120e0c0c111512121314141410181a"
    "1a1a1a181e1e1f1e1e1effc9000b080001000101011100ffc4001f0000010501010"
    "101010100000000000000000102030405060708090a0bffda0008010100003f00ff"
    "d9"
)


def test_lookup_reports_no_photo_by_default(client, registered):
    response = client.get("/v1/creators/tiktok/creator")
    from tipme_registry import signing
    record = signing.verify_envelope(client.public_key, response.json())
    assert record["has_photo"] is False


def test_upload_requires_management_token(client, registered):
    response = client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.jpg", io.BytesIO(JPEG_BYTES), "image/jpeg")},
    )
    assert response.status_code == 403


def test_upload_then_lookup_reports_photo(client, registered, management_token):
    upload = client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.jpg", io.BytesIO(JPEG_BYTES), "image/jpeg")},
        headers={"X-Management-Token": management_token},
    )
    assert upload.status_code == 204

    from tipme_registry import signing
    response = client.get("/v1/creators/tiktok/creator")
    record = signing.verify_envelope(client.public_key, response.json())
    assert record["has_photo"] is True

    fetched = client.get("/v1/creators/tiktok/creator/photo")
    assert fetched.status_code == 200
    assert fetched.content == JPEG_BYTES
    assert fetched.headers["content-type"] == "image/jpeg"


def test_photo_for_unregistered_handle_is_404(client):
    assert client.get("/v1/creators/tiktok/nobody/photo").status_code == 404


def test_upload_rejects_wrong_content_type(client, registered, management_token):
    response = client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.gif", io.BytesIO(b"not really a gif"), "image/gif")},
        headers={"X-Management-Token": management_token},
    )
    assert response.status_code == 400


def test_upload_rejects_oversized_photo(client, registered, management_token, monkeypatch):
    from tipme_registry import app as app_module
    app_module._settings.max_photo_bytes = 10

    response = client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.jpg", io.BytesIO(JPEG_BYTES), "image/jpeg")},
        headers={"X-Management-Token": management_token},
    )
    assert response.status_code == 400


def test_unregister_deletes_the_photo(client, registered, management_token):
    client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.jpg", io.BytesIO(JPEG_BYTES), "image/jpeg")},
        headers={"X-Management-Token": management_token},
    )
    delete = client.delete("/v1/creators/tiktok/creator",
                           headers={"X-Admin-Token": "test-admin-token"})
    assert delete.status_code == 204
    assert client.get("/v1/creators/tiktok/creator/photo").status_code == 404


def test_replacing_photo_format_does_not_leave_a_stale_file(client, registered, management_token):
    client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.jpg", io.BytesIO(JPEG_BYTES), "image/jpeg")},
        headers={"X-Management-Token": management_token},
    )
    png_bytes = bytes.fromhex(
        "89504e470d0a1a0a0000000d494844520000000100000001080600000"
        "01f15c4890000000a4944415478da6360000002000155bfaba5000000"
        "0049454e44ae426082"
    )
    replace = client.put(
        "/v1/creators/tiktok/creator/photo",
        files={"photo": ("me.png", io.BytesIO(png_bytes), "image/png")},
        headers={"X-Management-Token": management_token},
    )
    assert replace.status_code == 204

    fetched = client.get("/v1/creators/tiktok/creator/photo")
    assert fetched.headers["content-type"] == "image/png"
    assert fetched.content == png_bytes
