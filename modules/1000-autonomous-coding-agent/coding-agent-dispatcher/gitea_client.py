"""Gitea REST client for the dispatcher. Uses the bot's basic-auth creds to mint /
revoke per-run access tokens, sweep stale ones (a TTL backstop, since Gitea
tokens have no native expiry), comment on issues, and verify PRs. httpx-based."""

import logging
from datetime import datetime, timezone

import httpx


class GiteaClient:
    def __init__(self, *, api_url: str, bot_user: str, bot_password: str):
        self.api_url = api_url.rstrip("/")
        self.bot_user = bot_user
        self._auth = (bot_user, bot_password)

    # --- pure helpers (unit-tested) ---
    def _token_request(self, name: str) -> tuple[str, dict]:
        return name, {"name": name, "scopes": ["write:repository", "write:issue"]}

    def _comment_path(self, owner: str, repo: str, issue: int) -> str:
        return f"/repos/{owner}/{repo}/issues/{issue}/comments"

    def _pulls_path(self, owner: str, repo: str) -> str:
        return f"/repos/{owner}/{repo}/pulls"

    # --- network ops ---
    def mint_token(self, run_id: str) -> tuple[int, str]:
        """Create a per-run token (write:repository + write:issue). Returns
        (token_id, sha1). Revoke it with revoke_token() when the run ends."""
        name, payload = self._token_request(run_id)
        with httpx.Client(timeout=30) as c:
            r = c.post(f"{self.api_url}/users/{self.bot_user}/tokens",
                       auth=self._auth, json=payload)
            r.raise_for_status()
            data = r.json()
        return data["id"], data["sha1"]

    def revoke_token(self, token_id: str) -> None:
        try:
            with httpx.Client(timeout=30) as c:
                c.delete(f"{self.api_url}/users/{self.bot_user}/tokens/{token_id}",
                         auth=self._auth).raise_for_status()
        except Exception:
            logging.exception("token revoke failed for %s", token_id)

    def list_tokens(self) -> list[dict]:
        """List the bot's access tokens (id, name, created_at, ...)."""
        with httpx.Client(timeout=30) as c:
            r = c.get(f"{self.api_url}/users/{self.bot_user}/tokens",
                      auth=self._auth, params={"limit": 50})
            r.raise_for_status()
            return r.json()

    @staticmethod
    def _is_stale(token: dict, *, prefix: str, ttl_seconds: int, now: datetime) -> bool:
        """True if `token` is a per-run token (name starts with `prefix`) older
        than ttl_seconds. Pure (unit-tested). Anything that is not a per-run
        token, or whose created_at is missing/unparseable, is treated as NOT
        stale so the sweep never touches it."""
        name = token.get("name") or ""
        if not name.startswith(prefix):
            return False
        created = token.get("created_at")
        if not created:
            return False
        try:
            ts = datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            return False
        return (now - ts).total_seconds() > ttl_seconds

    def sweep_stale_tokens(self, *, prefix: str = "run-", ttl_seconds: int = 3600) -> int:
        """TTL backstop for missed revokes: Gitea access tokens never expire, so
        revoke any per-run token (name prefix `prefix`) older than ttl_seconds.
        Best-effort; returns the count revoked. `ttl_seconds` MUST exceed the max
        run duration so a token for an in-flight run is never revoked."""
        now = datetime.now(timezone.utc)
        revoked = 0
        try:
            for tok in self.list_tokens():
                if self._is_stale(tok, prefix=prefix, ttl_seconds=ttl_seconds, now=now):
                    self.revoke_token(str(tok["id"]))
                    revoked += 1
        except Exception:
            logging.exception("stale-token sweep failed")
        return revoked

    def comment(self, owner: str, repo: str, issue: int, body: str) -> None:
        with httpx.Client(timeout=30) as c:
            c.post(f"{self.api_url}{self._comment_path(owner, repo, issue)}",
                   auth=self._auth, json={"body": body}).raise_for_status()

    def find_pr_for_branch(self, owner: str, repo: str, head_branch: str) -> dict | None:
        """Return the open PR whose head is head_branch, else None."""
        with httpx.Client(timeout=30) as c:
            r = c.get(f"{self.api_url}{self._pulls_path(owner, repo)}",
                      auth=self._auth, params={"state": "open"})
            r.raise_for_status()
            for pr in r.json():
                if (pr.get("head") or {}).get("ref") == head_branch:
                    return pr
        return None
