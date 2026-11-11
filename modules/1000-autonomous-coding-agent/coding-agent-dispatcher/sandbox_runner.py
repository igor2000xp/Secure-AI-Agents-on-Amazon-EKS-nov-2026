"""Claim a coding sandbox from a warm pool, drive Claude Code in it, release it.

Driven by the agent-sandbox SDK against the control plane installed by
terraform/agent-sandbox.tf. The dispatcher (server.py) calls run_coding_task(...)
after minting a per-run Gitea token.

WHAT THE SDK REPLACED. This module used to build a Pod manifest by hand, poll
for Ready, push files in as base64 chunks over the `kubectl exec` websocket, and
parse exit codes off the exec error channel — plumbing with its own bug history
(an unclosed stdin channel that left files written as zero bytes while
`base64 -d` blocked forever). That is now four SDK calls:

    sandbox = client.create_sandbox(warmpool=...)   # attach to a booted guest
    sandbox.files.write("task.md", ...)             # upload, out-of-band
    handle = sandbox.commands.start("bash run.sh")  # streamed exec
    for event in handle.events(): ...               # relay as it happens

NO ROUTER. agent-sandbox ships a sandbox-router for fanning external HTTP at
sandboxes; we do not use it. This process is already in-cluster, so it dials
sandboxd over the Sandbox's own Service (`in-cluster-service` mode). That also
sidesteps a documented ambiguity about whether the router can carry sandboxd's
gRPC ProcessService — which is exactly the call this lab depends on.

WHERE THE ISOLATION LIVES. Not here — in the SandboxTemplate
(terraform/manifests/agent-sandbox-coding-template.yaml).
`runtimeClassName: isolated-sandbox` makes each sandbox a Nitro Sandbox
micro-VM; the template's egress allowlist limits it to the AI gateway and
Gitea; it mounts no service account token. The only credential the guest ever
holds is a per-run Gitea token this module writes in and the dispatcher revokes.

LIVE OUTPUT. `commands.start()` streams the session back as it is produced and
this process prints each line to its own stdout, so a run is followed with
`kubectl logs -f deployment/coding-agent-dispatcher` — a long-lived Deployment —
instead of racing to attach to an ephemeral sandbox pod before it is deleted.
"""

import logging
import os
import sys

from k8s_agent_sandbox import SandboxClient, SandboxdInClusterConnectionConfig
from k8s_agent_sandbox.models import ProcessExitEvent

log = logging.getLogger("coding-agent-dispatcher.sandbox_runner")

# --- agent-sandbox knobs (env-overridable so ops can retune without a rebuild) ---
# Warm pool to claim from, and the namespace holding the pool and the claims.
# The analysis lab claims a different pool in the same namespace.
SANDBOX_WARMPOOL = os.environ.get("SANDBOX_WARMPOOL", "coding-agent-pool")
SANDBOX_NAMESPACE = os.environ.get("SANDBOX_NAMESPACE", "agent-sandbox")

# sandboxd's listeners inside the guest. `in-cluster-service` resolves
# Sandbox.status.serviceFQDN, which needs `spec.service: true` on the template.
SANDBOXD_REST_PORT = int(os.environ.get("SANDBOXD_REST_PORT", "8080"))
SANDBOXD_GRPC_PORT = int(os.environ.get("SANDBOXD_GRPC_PORT", "9090"))

# sandboxd's root, and so where uploaded files land. Paths passed to
# files.write() are sandbox-RELATIVE: the SDK normalises them against this root
# and rejects absolute paths and `..` traversal. The generated scripts below
# still use absolute paths, because they run inside the guest.
SANDBOX_ROOT = os.environ.get("SANDBOX_ROOT", "/workspace")

RUN_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_RUN_TIMEOUT", "1500"))
READY_TIMEOUT_SECONDS = int(os.environ.get("SANDBOX_READY_TIMEOUT", "300"))
# Controller-side TTL, so a claim cannot outlive this process and hold a scarce
# per-node sandbox slot if the dispatcher dies mid-run.
SHUTDOWN_AFTER_SECONDS = int(os.environ.get(
    "SANDBOX_SHUTDOWN_AFTER", str(RUN_TIMEOUT_SECONDS + 300)))

# In-cluster endpoints injected into the guest.
GITEA_INTERNAL = os.environ.get("GITEA_INTERNAL_URL", "http://gitea-http.gitea.svc.cluster.local:3000")
MODEL_BASE_URL = os.environ.get("MODEL_BASE_URL", "http://ai-gateway.envoy-gateway-system.svc.cluster.local/anthropic")
MODEL_MAIN = os.environ.get("MODEL_MAIN", "claude-sonnet")
MODEL_SMALL = os.environ.get("MODEL_SMALL", "claude-haiku")

MAX_OUTPUT_BYTES = 64 * 1024


def cap_output(text: str | None) -> str:
    if not text:
        return ""
    data = text.encode("utf-8")
    if len(data) <= MAX_OUTPUT_BYTES:
        return text
    return data[:MAX_OUTPUT_BYTES].decode("utf-8", errors="ignore") + "...[truncated]"


STREAM_FILTER_PY = '''import json
import sys


def hint(tool_input):
    for key in ("file_path", "command", "pattern", "path", "url"):
        val = tool_input.get(key)
        if val:
            return str(val).replace("\\n", " ")[:120]
    return ""


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = event.get("type")
    if kind == "system" and event.get("subtype") == "init":
        print("[claude] session start (model %s)" % event.get("model", "?"), flush=True)
    elif kind == "assistant":
        for block in event.get("message", {}).get("content", []) or []:
            if block.get("type") == "text" and block.get("text", "").strip():
                for text_line in block["text"].strip().splitlines():
                    print("[claude] %s" % text_line, flush=True)
            elif block.get("type") == "tool_use":
                print("[claude] tool %s: %s" % (block.get("name", "?"), hint(block.get("input") or {})), flush=True)
    elif kind == "result":
        print("[claude] done: %s (%s turns)" % (event.get("subtype", "?"), event.get("num_turns", "?")), flush=True)
'''


def _report_blocked_script(*, owner: str, repo: str, issue: int) -> str:
    """Post {SANDBOX_ROOT}/BLOCKED.md as a comment on the triggering issue.

    Injected as {SANDBOX_ROOT}/report-blocked.sh so the AGENT can report a blocker
    itself, mid-run, the moment it hits one — rather than the dispatcher
    inferring "something went wrong" from an empty diff after the fact.

    Why a script instead of telling the model to curl: the per-run Gitea token
    must not enter the prompt (it would then pass through the LLM, and the whole
    credential story of this lab is that it does not). Here the token is read
    from the environment inside the guest, so the task file can say "run this
    script" without ever naming a secret. It also keeps JSON escaping out of the
    model's hands — a blocker report full of quotes and newlines is exactly the
    payload a hand-written curl gets wrong.

    Writes {SANDBOX_ROOT}/.blocked-posted on success so the run.sh safety net below can
    tell whether the agent already reported and avoid double-commenting.
    """
    return f"""set -uo pipefail
# Posts {SANDBOX_ROOT}/BLOCKED.md to issue #{issue}. Safe to call more than once.
if [ ! -s {SANDBOX_ROOT}/BLOCKED.md ]; then
  echo "report-blocked: {SANDBOX_ROOT}/BLOCKED.md is missing or empty; nothing to post" >&2
  exit 1
fi
BODY=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < {SANDBOX_ROOT}/BLOCKED.md)
if curl -sS --fail-with-body -X POST \\
  "{GITEA_INTERNAL}/api/v1/repos/{owner}/{repo}/issues/{issue}/comments" \\
  -H "Authorization: token $GITEA_TOKEN" -H "content-type: application/json" \\
  -d "{{\\"body\\":$BODY}}" >/dev/null; then
  : > {SANDBOX_ROOT}/.blocked-posted
  echo "report-blocked: posted the blocker report to issue #{issue}"
else
  echo "report-blocked: FAILED to post the report to issue #{issue}" >&2
  exit 1
fi
"""


def _run_script(*, owner: str, repo: str, issue: int, branch: str, token: str) -> str:
    """Bash the sandbox executes. Self-contained: it exports its own HOME (the
    runtime runs as UID 1000 with no writable home otherwise), GITEA_TOKEN, and
    the model env, then clones, runs Claude Code, runs the repo's tests, and
    pushes + opens a PR (whose body carries the test summary) only if there is a
    commit to push.

    A GLOBAL gitignore is configured before the clone so build/test artifacts
    (__pycache__, *.pyc, .pytest_cache) are never staged by `git add -A`, even
    when the target repo ships no .gitignore — Claude/pytest create these during
    the run, and without this they leak into the PR diff.

    With Nitro Sandboxes this script is written to /work (the pod's writable
    overlay, owned by UID 1000) and run with `bash {SANDBOX_ROOT}/run.sh`. HOME is set to
    /work here so git config, credentials, and Claude Code's dotfiles all land
    on the overlay.
    """
    host = GITEA_INTERNAL.split("://", 1)[1]  # gitea-http...:3000
    scheme = GITEA_INTERNAL.split("://", 1)[0]
    host_only = host.split(":", 1)[0]  # gitea-http...  (no port, for DNS resolve)
    return f"""set -euo pipefail
# No `tee /proc/1/fd/1` here. Under sandboxd PID 1 is the daemon itself, not
# this script, so writing to its stdout would interleave with the daemon's own
# logs. The dispatcher streams this script's stdout back over
# ProcessService.Start and prints it to ITS log instead, which is also a log
# that still exists after the sandbox is gone.
export HOME={SANDBOX_ROOT}
export GITEA_TOKEN="{token}"
export ANTHROPIC_BASE_URL="{MODEL_BASE_URL}"
export ANTHROPIC_API_KEY="not-needed"
export ANTHROPIC_MODEL="{MODEL_MAIN}"
export ANTHROPIC_SMALL_FAST_MODEL="{MODEL_SMALL}"
git config --global user.email "coding-agent-bot@example.com"
git config --global user.name "coding-agent-bot"
git config --global credential.helper store
printf '__pycache__/\\n*.py[cod]\\n.pytest_cache/\\n.venv/\\n' > "$HOME/.gitignore_global"
git config --global core.excludesFile "$HOME/.gitignore_global"
printf '{scheme}://coding-agent-bot:%s@{host}\\n' "$GITEA_TOKEN" > "$HOME/.git-credentials"
cd {SANDBOX_ROOT}
# Wait for cluster networking to be ready before cloning. Under NetworkPolicy
# enforcement (Cilium), a Nitro Sandbox micro-VM can reach phase=Running a moment before
# its egress policy + identity are fully programmed, so the very first DNS query
# can be dropped ("Could not resolve host"). Poll until the Gitea host resolves
# (DNS rule live) AND the git endpoint answers, with a bounded retry, so the run
# is not lost to a startup race. Best-effort: proceed after the budget anyway so
# a genuine failure still surfaces in the clone error.
for i in $(seq 1 30); do
  if getent hosts {host_only} >/dev/null 2>&1 || nslookup {host_only} >/dev/null 2>&1; then
    break
  fi
  echo "[netwait] DNS for {host_only} not ready yet (attempt $i/30)"
  sleep 2
done
# Clone with a few retries in case the first connection races policy programming.
clone_ok=0
for i in $(seq 1 5); do
  if git clone {scheme}://{host}/{owner}/{repo}.git repo; then clone_ok=1; break; fi
  echo "[netwait] clone attempt $i failed, retrying in 3s"
  rm -rf repo
  sleep 3
done
[ "$clone_ok" = "1" ] || {{ echo "fatal: clone failed after retries"; exit 1; }}
cd repo
git checkout -b {branch}
BASE_SHA=$(git rev-parse HEAD)
# Redirect stdin from /dev/null: current Claude Code (headless -p) treats an open,
# empty stdin as "input pending" and stalls ("no stdin data received"), doing no
# tool work. </dev/null makes it use the -p prompt argument and run to completion.
# stream-json + the renderer turns the session into one short line per event
# (assistant text, tool calls, result) so the mirrored pod log shows Claude
# working live instead of going dark for the whole run.
# Capture the rendered transcript as well as streaming it, so a failure report
# can quote the tail of the session. PIPESTATUS[0] is claude's own status —
# without it, `|| true` or the pipe's exit code hides a crashed session.
set +e
claude -p "$(cat {SANDBOX_ROOT}/task.md)" --dangerously-skip-permissions \\
  --output-format stream-json --verbose </dev/null \\
  | python3 {SANDBOX_ROOT}/stream_filter.py | tee {SANDBOX_ROOT}/claude.log
CLAUDE_RC=${{PIPESTATUS[0]}}
set -e
echo "[run] claude exited with status $CLAUDE_RC"
# Commit anything Claude left uncommitted. Newer Claude Code commits its own work,
# so this is best-effort — the push gate below (branch advanced past BASE_SHA) is
# true whether Claude committed or we commit here, avoiding the trap where a
# Claude-made commit leaves `git commit` here with nothing to do.
git add -A
git commit -m "{branch}: automated change for issue #{issue}" || true
if [ "$(git rev-parse HEAD)" != "$BASE_SHA" ]; then
  git push -u origin {branch}
  # Run the repo's tests. The agent is told to pip install requirements.txt
  # first, so by here the deps should be present; pytest itself is in the image
  # so this still runs (and reports) if they are not. Capture the summary for
  # the PR
  # body. Non-fatal: a failing/absent suite still opens the PR, flagged as such.
  set +e
  pytest -q > {SANDBOX_ROOT}/pytest.txt 2>&1
  TEST_RC=$?
  set -e
  if [ "$TEST_RC" -eq 0 ]; then TEST_HDR="### ✅ Tests passed"
  elif [ "$TEST_RC" -eq 5 ]; then TEST_HDR="### ⚠️ No tests collected"
  else TEST_HDR="### ❌ Tests failed (pytest exit $TEST_RC)"; fi
  {{
    echo "Automated PR for issue #{issue}."
    echo
    echo "$TEST_HDR"
    echo
    echo '```'
    tail -n 30 {SANDBOX_ROOT}/pytest.txt
    echo '```'
  }} > {SANDBOX_ROOT}/prbody.md
  # Build the JSON body with Python so arbitrary pytest output is safely escaped.
  BODY=$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' < {SANDBOX_ROOT}/prbody.md)
  # Response body goes to a FILE, not stdout. Gitea's PR object is ~4KB of JSON
  # that embeds the repo twice, and this stdout is relayed to the dispatcher log
  # that participants watch — dumping it buried the whole session transcript.
  PR_CODE=$(curl -sS -o {SANDBOX_ROOT}/pr.json -w '%{{http_code}}' \
    -X POST "{GITEA_INTERNAL}/api/v1/repos/{owner}/{repo}/pulls" \
    -H "Authorization: token $GITEA_TOKEN" -H "content-type: application/json" \
    -d "{{\\"head\\":\\"{branch}\\",\\"base\\":\\"main\\",\\"title\\":\\"Fix issue #{issue}\\",\\"body\\":$BODY}}") || true
  if [ "$PR_CODE" = "201" ]; then
    echo "[run] opened PR: $(python3 -c "import json;print(json.load(open('{SANDBOX_ROOT}/pr.json'))['html_url'])" 2>/dev/null)"
  else
    # Keep the failure readable but bounded. The dispatcher also looks the PR up
    # by branch, so it reports the outcome on the issue either way.
    echo "[run] PR creation returned HTTP $PR_CODE"
    head -c 300 {SANDBOX_ROOT}/pr.json
    echo
  fi
else
  echo "no changes to commit; skipping push and PR"
  # Safety net. The task file asks the agent to report its own blockers via
  # report-blocked.sh, which is better (it knows WHY it stopped and can say so
  # in its own words, while the run is still live). But a model that crashes,
  # is killed on timeout, or simply ignores the instruction would otherwise
  # leave the issue with nothing but the dispatcher's "no PR was created". So
  # if the agent produced no commit AND never posted, post the transcript tail
  # on its behalf.
  if [ ! -f {SANDBOX_ROOT}/.blocked-posted ]; then
    {{
      echo "### ⚠️ No changes were produced"
      echo
      echo "Claude Code exited with status $CLAUDE_RC and left no commit on \\`{branch}\\`, so there is nothing to open a pull request from."
      echo
      echo "Last lines of the session:"
      echo
      echo '```'
      tail -n 40 {SANDBOX_ROOT}/claude.log 2>/dev/null || echo "(no transcript captured)"
      echo '```'
    }} > {SANDBOX_ROOT}/BLOCKED.md
    bash {SANDBOX_ROOT}/report-blocked.sh || echo "[run] could not post the fallback report"
  fi
fi
"""


def _task_md(*, owner: str, repo: str, issue: int, branch: str, title: str, body: str) -> str:
    return f"""# Task (from issue #{issue}: {title})

{body}

## Instructions
- You are on a fresh branch `{branch}` inside the cloned repo at {SANDBOX_ROOT}/repo.
- Implement the change described above. Keep it minimal and correct.
- Add or update unit tests covering your change, and run them to confirm they
  pass (`pytest` is available offline).
- Commit your work with a clear message.
- Do NOT push or open a PR yourself: the wrapper pushes the branch, runs the test
  suite, and opens the PR with the test summary in its description.

## If you get blocked, say so on the issue
You are running inside a locked-down sandbox. Egress is an allowlist: you can
reach this Gitea server, the model gateway, and limited Internet destinations. 
Everything else is denied, so anything that fetches from elsewhere
on the network will fail, and no amount of retrying will change that.

The repo's Python dependencies are NOT pre-installed. If it ships a
requirements.txt, run `pip install -r requirements.txt` before running the
tests. That works, because the network allowlist allows it.

If you cannot complete the task, do NOT stop silently and do NOT invent a
workaround that fakes the result. Report it, in two steps:

1. Write a short Markdown explanation to `{SANDBOX_ROOT}/BLOCKED.md`. Say what you were
   trying to do, the exact command that failed, and the error it returned,
   verbatim. If the cause was the sandbox's network policy, say that plainly
   and name the host you could not reach.
2. Run `bash {SANDBOX_ROOT}/report-blocked.sh`. That posts the file as a comment on
   issue #{issue} so whoever filed it can see what happened.

Then finish your turn. Do that as soon as you are sure you are blocked, rather
than at the end of a long series of retries — the comment is more useful than a
completed run that quietly did the wrong thing.

Partial progress is still worth committing: if some of the task succeeded,
commit that work AND report what was left undone and why.
"""



def _client() -> SandboxClient:
    """SandboxClient dialing sandboxd directly over the Sandbox's Service.

    No router and no port-forward: this process runs in the cluster, so cluster
    DNS reaches the guest. Service mode (rather than pod IP) survives a pod
    being replaced and cannot address a recycled IP.
    """
    return SandboxClient(
        connection_config=SandboxdInClusterConnectionConfig(
            mode="in-cluster-service",
            rest_port=SANDBOXD_REST_PORT,
            grpc_port=SANDBOXD_GRPC_PORT,
        ),
    )


def run_coding_task(*, owner: str, repo: str, issue: int, title: str, body: str,
                    token: str) -> dict:
    """Clone the repo in a fresh coding sandbox, run Claude Code, push + PR.

    Returns {stdout, stderr, exit_code, branch, agent_reported}. Always releases
    the claim.
    """
    branch = f"agent/issue-{issue}"
    client = _client()
    sandbox = client.create_sandbox(
        warmpool=SANDBOX_WARMPOOL,
        namespace=SANDBOX_NAMESPACE,
        sandbox_ready_timeout=READY_TIMEOUT_SECONDS,
        shutdown_after_seconds=SHUTDOWN_AFTER_SECONDS,
        labels={"app": "coding-sandbox", "coding-agent.workshop/issue": str(issue)},
    )
    try:
        # Creds, task and scripts all go in as FILES, out-of-band. Nothing here
        # travels through the model, and the task file names no secret — it
        # tells the agent to run report-blocked.sh, which reads the token from
        # the guest environment.
        sandbox.files.write("stream_filter.py", STREAM_FILTER_PY, timeout=60)
        sandbox.files.write(
            "report-blocked.sh",
            _report_blocked_script(owner=owner, repo=repo, issue=issue),
            timeout=60,
        )
        sandbox.files.write(
            "task.md",
            _task_md(owner=owner, repo=repo, issue=issue, branch=branch,
                     title=title, body=body),
            timeout=60,
        )
        sandbox.files.write(
            "run.sh",
            _run_script(owner=owner, repo=repo, issue=issue, branch=branch,
                        token=token),
            timeout=60,
        )

        # Streamed exec. Each chunk is relayed to this process's stdout as it
        # arrives, so `kubectl logs -f deployment/coding-agent-dispatcher`
        # follows the session live. `data` is raw bytes and a multi-byte
        # character can straddle two chunks, so decode the accumulated stream
        # rather than each chunk.
        handle = sandbox.commands.start(
            f"bash {SANDBOX_ROOT}/run.sh",
            timeout=120,
            cwd=SANDBOX_ROOT,
        )
        out_chunks: list[bytes] = []
        err_chunks: list[bytes] = []
        exit_code = None
        pending = b""
        try:
            for event in handle.events():
                if isinstance(event, ProcessExitEvent):
                    exit_code = event.exit_code
                    break
                if event.type == "stdout":
                    out_chunks.append(event.data)
                    pending += event.data
                    # Print whole lines only; hold a partial line back.
                    *lines, pending = pending.split(b"\n")
                    for line in lines:
                        print(f"[issue-{issue}] {line.decode('utf-8', 'replace')}",
                              flush=True)
                else:
                    err_chunks.append(event.data)
        finally:
            if pending:
                print(f"[issue-{issue}] {pending.decode('utf-8', 'replace')}", flush=True)
            handle.close()

        stdout = b"".join(out_chunks).decode("utf-8", "replace")
        stderr = b"".join(err_chunks).decode("utf-8", "replace")

        # Did anything in the guest already comment on the issue? Checked before
        # the claim is released, so the dispatcher does not pile a generic
        # "no PR was created" on top of a specific explanation.
        agent_reported = False
        try:
            agent_reported = sandbox.files.exists(".blocked-posted", timeout=30)
        except Exception:
            logging.exception("could not check the blocker marker; assuming not posted")

        return {
            "stdout": cap_output(stdout),
            "stderr": cap_output(stderr),
            "exit_code": exit_code if exit_code is not None else -1,
            "branch": branch,
            "agent_reported": agent_reported,
        }
    finally:
        try:
            sandbox.terminate()
        except Exception:  # single-use; never mask the real result
            logging.exception("sandbox terminate failed (the claim TTL will reap it)")
