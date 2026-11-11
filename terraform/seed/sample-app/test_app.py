from fastapi.testclient import TestClient

from app import app

client = TestClient(app)


def test_root_ok():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["service"] == "sample-app"
