"""Coding-agent dispatcher. Receives Gitea issue webhooks, verifies the HMAC, and
orchestrates a coding run in an isolated microVM. Returns 200 immediately and
processes asynchronously; status is posted back as issue comments."""

import logging
import os
import threading
import time
import uuid

from fastapi import BackgroundTasks, FastAPI, Header, Request, Response

from gitea_client import GiteaClient
from sandbox_runner import run_coding_task
from webhook import should_trigger, verify_signature

# This container's log is what participants watch during a run (see
# watch-sandbox.sh), so the format drops the "LEVEL:logger:" prefix that
# basicConfig defaults to. The relayed session lines already carry their own
# [issue-N] [claude] tags, and a wall of INFO: prefixes in front of them just
# costs width.
logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("coding-agent-dispatcher")

# httpx logs one INFO line per request, including the full URL. For this service
# that is every Gitea API call (comment, find PR, mint/revoke token) on every
# run, which says nothing the dispatcher's own messages do not. Failures still
# surface, because they raise rather than being logged here.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)

WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"]
BOT_USER = os.environ["BOT_USERNAME"]
BOT_PASS = os.environ["BOT_PASSWORD"]
TRIGGER_LABEL = os.environ.get("TRIGGER_LABEL", "agent")
GITEA_API = os.environ.get("GITEA_API_URL", "http://gitea-http.gitea.svc.cluster.local:3000/api/v1")
# TTL backstop for per-run tokens. Gitea tokens never expire, so a background
# sweep revokes any run-* token older than the TTL in case a per-run revoke was
# missed (dispatcher crash / transient error). TOKEN_TTL_SECONDS MUST exceed the
# max run duration (SANDBOX_READY_TIMEOUT + SANDBOX_RUN_TIMEOUT) so a token for an
# in-flight run is never revoked.
TOKEN_TTL_SECONDS = int(os.environ.get("TOKEN_TTL_SECONDS", "3600"))
TOKEN_SWEEP_INTERVAL = int(os.environ.get("TOKEN_SWEEP_INTERVAL", "300"))

app = FastAPI()
gitea = GiteaClient(api_url=GITEA_API, bot_user=BOT_USER, bot_password=BOT_PASS)


def _token_sweep_loop() -> None:
    """TTL backstop: periodically revoke any per-run token older than the TTL, so
    one whose per-run revoke was missed cannot linger (Gitea tokens never expire)."""
    while True:
        time.sleep(TOKEN_SWEEP_INTERVAL)
        try:
            n = gitea.sweep_stale_tokens(prefix="run-", ttl_seconds=TOKEN_TTL_SECONDS)
            if n:
                log.info("token sweep revoked %d stale per-run token(s)", n)
        except Exception:
            log.exception("token sweep loop error")


@app.on_event("startup")
def _start_token_sweeper() -> None:
    threading.Thread(target=_token_sweep_loop, name="token-sweeper", daemon=True).start()


def _process(payload: dict) -> None:
    issue = payload["issue"]
    number = issue["number"]
    repo = payload["repository"]
    owner = repo["owner"]["login"]
    name = repo["name"]
    run_id = f"run-{number}-{uuid.uuid4().hex[:8]}"
    token_id = None
    try:
        gitea.comment(owner, name, number, "🤖 Working on this in an isolated sandbox…")
        token_id, token = gitea.mint_token(run_id)
        result = run_coding_task(owner=owner, repo=name, issue=number,
                                 title=issue.get("title", ""), body=issue.get("body", "") or "",
                                 token=token)
        pr = gitea.find_pr_for_branch(owner, name, result["branch"])
        if pr:
            gitea.comment(owner, name, number, f"✅ Opened PR: {pr['html_url']}")
        elif result.get("agent_reported"):
            # The sandbox already commented — either the agent reported its own
            # blocker via report-blocked.sh, or run.sh's safety net posted the
            # transcript tail. Adding "no PR was created" on top of a specific
            # explanation only buries it.
            log.info("no PR for issue #%s; the sandbox already reported why", number)
        else:
            # Fallback for a run that produced neither a PR nor a report.
            #
            # Tail STDOUT, not stderr. The previous `stderr or stdout` put
            # stderr first, and git/curl write progress there on every single
            # run — so this comment reliably showed clone progress chatter
            # instead of the session transcript that explains the outcome.
            tail = (result["stdout"] or "").strip()[-1500:]
            err_tail = (result["stderr"] or "").strip()[-500:]
            msg = ["⚠️ No pull request was created, and the sandbox did not report a reason."]
            if tail:
                msg.append(f"Last lines of the run:\n\n```\n{tail}\n```")
            if err_tail:
                msg.append(f"stderr:\n\n```\n{err_tail}\n```")
            gitea.comment(owner, name, number, "\n\n".join(msg))
    except Exception as e:
        log.exception("coding run failed")
        try:
            gitea.comment(owner, name, number, f"❌ The coding agent failed: `{e}`")
        except Exception:
            pass
    finally:
        if token_id is not None:
            gitea.revoke_token(str(token_id))


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.post("/webhook")
async def webhook(request: Request, background: BackgroundTasks,
                  x_gitea_signature: str | None = Header(default=None)) -> Response:
    body = await request.body()
    if not verify_signature(WEBHOOK_SECRET, body, x_gitea_signature):
        return Response(status_code=401, content="bad signature")
    payload = await request.json()
    if should_trigger(payload, trigger_label=TRIGGER_LABEL, bot_user=BOT_USER):
        background.add_task(_process, payload)
        return Response(status_code=202, content="accepted")
    return Response(status_code=200, content="ignored")
