from datetime import datetime, timedelta, timezone

from gitea_client import GiteaClient


def _client():
    return GiteaClient(
        api_url="http://gitea-http.gitea.svc.cluster.local:3000/api/v1",
        bot_user="coding-agent-bot",
        bot_password="pw",
    )


def test_token_payload_scopes():
    c = _client()
    name, payload = c._token_request("run-abc")
    assert name == "run-abc"
    assert set(payload["scopes"]) == {"write:repository", "write:issue"}


def test_comment_path():
    c = _client()
    assert c._comment_path("workshop-user", "sample-app", 7) == \
        "/repos/workshop-user/sample-app/issues/7/comments"


def test_pulls_path():
    c = _client()
    assert c._pulls_path("workshop-user", "sample-app") == \
        "/repos/workshop-user/sample-app/pulls"


def test_is_stale_only_expired_run_tokens():
    now = datetime(2026, 7, 20, 12, 0, 0, tzinfo=timezone.utc)
    is_stale = GiteaClient._is_stale

    def tok(name, minutes_ago, created_key="created_at"):
        t = {"id": 1, "name": name}
        if minutes_ago is not None:
            t[created_key] = (now - timedelta(minutes=minutes_ago)).isoformat()
        return t

    # A run-* token older than the TTL is stale (revocable).
    assert is_stale(tok("run-6-def", 120), prefix="run-", ttl_seconds=3600, now=now) is True
    # A run-* token younger than the TTL (e.g. an in-flight run) is NOT stale.
    assert is_stale(tok("run-5-abc", 10), prefix="run-", ttl_seconds=3600, now=now) is False
    # A non-run token is never touched, even if old.
    assert is_stale(tok("gitea-mcp", 120), prefix="run-", ttl_seconds=3600, now=now) is False
    # Missing / unparseable created_at is treated as NOT stale.
    assert is_stale(tok("run-7-xyz", None), prefix="run-", ttl_seconds=3600, now=now) is False
    # Gitea's trailing-Z timestamp form parses too.
    assert is_stale({"id": 2, "name": "run-8", "created_at": "2026-07-20T09:00:00Z"},
                    prefix="run-", ttl_seconds=3600, now=now) is True
