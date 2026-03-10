import hashlib
import hmac

from fastapi.testclient import TestClient

from filer.app import Settings, create_app


class FakeWebDavClient:
    """Fake async HTTP client for WebDAV tests. Acts as its own factory (callable → context manager)."""

    def __init__(self, *, healthy=True, stored_content=b"", stored_content_type="text/plain"):
        self.healthy = healthy
        self.stored_content = stored_content
        self.stored_content_type = stored_content_type
        self.put_calls: list[dict] = []

    # factory: called by http_client_factory()
    def __call__(self):
        return self

    # async context manager
    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def request(self, method, url, **kwargs):
        if not self.healthy:
            raise RuntimeError("unavailable")
        return _FakeResponse(207)

    async def put(self, url, content, headers, auth):
        self.put_calls.append({"url": url, "content": content, "headers": headers})
        return _FakeResponse(201)

    async def get(self, url, auth):
        return _FakeResponse(200, self.stored_content, self.stored_content_type)


class _FakeResponse:
    def __init__(self, status_code: int, content: bytes = b"", content_type: str = ""):
        self.status_code = status_code
        self.content = content
        self.headers = {"content-type": content_type} if content_type else {}


def make_settings(max_size=1024):
    return Settings(
        filer_secret="shared-secret",
        storage_box_url="https://u123456.your-storagebox.de",
        storage_box_user="u123456",
        storage_box_pass="hunter2",
        max_size=max_size,
    )


def make_token(secret, random, filename, filesize):
    message = f"{random}/{filename} {filesize}".encode()
    return hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()


def test_health_returns_ok():
    client = TestClient(create_app(settings=make_settings(), http_client_factory=FakeWebDavClient()))

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_returns_503_when_storage_box_is_unavailable():
    client = TestClient(
        create_app(settings=make_settings(), http_client_factory=FakeWebDavClient(healthy=False))
    )

    response = client.get("/health")

    assert response.status_code == 503
    assert response.json() == {"detail": "Storage Box unavailable"}


def test_upload_rejects_invalid_token():
    client = TestClient(create_app(settings=make_settings(), http_client_factory=FakeWebDavClient()))

    response = client.put(
        "/abc/file.txt?v=invalid",
        content=b"hello",
        headers={"content-type": "text/plain"},
    )

    assert response.status_code == 403
    assert response.json() == {"detail": "Invalid token"}


def test_upload_rejects_files_over_limit():
    settings = make_settings(max_size=4)
    token = make_token(settings.filer_secret, "abc", "file.txt", 5)
    client = TestClient(create_app(settings=settings, http_client_factory=FakeWebDavClient()))

    response = client.put(
        f"/abc/file.txt?v={token}",
        content=b"hello",
        headers={"content-type": "text/plain"},
    )

    assert response.status_code == 400
    assert response.json() == {"detail": "File too large"}


def test_upload_stores_object_in_storage_box():
    settings = make_settings()
    fake = FakeWebDavClient()
    body = b"hello world"
    token = make_token(settings.filer_secret, "abc", "file.txt", len(body))
    client = TestClient(create_app(settings=settings, http_client_factory=fake))

    response = client.put(
        f"/abc/file.txt?v={token}",
        content=body,
        headers={"content-type": "text/plain"},
    )

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert fake.put_calls == [
        {
            "url": "https://u123456.your-storagebox.de/abc/file.txt",
            "content": body,
            "headers": {"Content-Type": "text/plain"},
        }
    ]


def test_download_proxies_from_storage_box():
    fake = FakeWebDavClient(stored_content=b"file data", stored_content_type="image/png")
    client = TestClient(create_app(settings=make_settings(), http_client_factory=fake))

    response = client.get("/abc/photo.png")

    assert response.status_code == 200
    assert response.content == b"file data"
    assert response.headers["content-type"] == "image/png"
