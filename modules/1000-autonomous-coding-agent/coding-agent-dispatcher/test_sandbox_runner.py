"""Tests for the pure script builders.

These would have caught the no-shell / no-env-passthrough bug: run.sh MUST be
self-contained (export its own HOME + GITEA_TOKEN) because the dispatcher starts
it as a bare `bash /workspace/run.sh` and passes no environment.

The sandbox is now claimed from an agent-sandbox warm pool rather than built as
a Pod here, so there is no manifest builder to test — the pod spec lives in
terraform/manifests/agent-sandbox-coding-template.yaml and is validated against
the upstream CRD schema instead. Files land on sandboxd's /workspace root.

The builders stay importable with the SDK stubbed, so these run without the
agent-sandbox client installed.
"""

import sys
import types

# Stub the SDK: these tests exercise only the pure string builders.
_sdk = types.ModuleType("k8s_agent_sandbox")
_sdk.SandboxClient = object
_sdk.SandboxdInClusterConnectionConfig = object
sys.modules.setdefault("k8s_agent_sandbox", _sdk)
_models = types.ModuleType("k8s_agent_sandbox.models")
_models.ProcessExitEvent = type("ProcessExitEvent", (object,), {})
sys.modules.setdefault("k8s_agent_sandbox.models", _models)

import inspect
import json
import subprocess
import sys

from sandbox_runner import (
    SANDBOX_ROOT,
    STREAM_FILTER_PY,
    _report_blocked_script,
    _run_script,
    _task_md,
)


def test_run_script_is_self_contained():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="TKN123")
    # Env set INSIDE the script (no reliance on a shell env-prefix or passthrough).
    assert "export HOME=/work" in s
    assert 'export GITEA_TOKEN="TKN123"' in s
    assert 'export ANTHROPIC_BASE_URL=' in s
    assert 'export ANTHROPIC_MODEL="claude-sonnet"' in s


def test_run_script_clone_and_branch():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="T")
    assert "git clone http://gitea-http.gitea.svc.cluster.local:3000/acme/app.git repo" in s
    assert "git checkout -b agent/issue-5" in s


def test_run_script_credentials_and_push_guard():
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "credential.helper store" in s
    assert '"$HOME/.git-credentials"' in s
    # Push + PR only happen when the branch advanced past the base commit
    # (no stray empty branches).
    assert '"$(git rev-parse HEAD)" != "$BASE_SHA"' in s


def test_run_script_uses_work_overlay_paths():
    # With Nitro Sandboxes the run files live on the pod's /work emptyDir overlay, not /app.
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert f"cd {SANDBOX_ROOT}" in s
    assert f"cat {SANDBOX_ROOT}/task.md" in s
    assert f"python3 {SANDBOX_ROOT}/stream_filter.py" in s


def test_task_md_carries_issue_context():
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="Add health", body="Return ok")
    assert "issue #9" in m
    assert "Add health" in m
    assert "Return ok" in m
    assert f"{SANDBOX_ROOT}/repo" in m


def test_run_script_renders_the_session_one_line_per_event():
    """stream-json through the filter is what makes the relayed log readable.

    The dispatcher prints whatever this script writes to stdout, so without the
    renderer the participant would get one opaque JSON blob per event instead of
    a line per tool call.
    """
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "--output-format stream-json --verbose" in s
    assert f"python3 {SANDBOX_ROOT}/stream_filter.py" in s


def test_run_script_does_not_write_to_pid_1():
    """Under sandboxd, PID 1 is the daemon, not run.sh.

    The old script did `exec > >(tee /proc/1/fd/1)` so `kubectl logs -f` on the
    sandbox pod showed the run. Doing that now would interleave with sandboxd's
    own logs; the dispatcher streams stdout back over ProcessService instead.
    """
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "exec > >(tee" not in s


def test_run_script_paths_are_under_the_sandboxd_root():
    """Every injected file lands under sandboxd's root, not the old /work."""
    s = _run_script(owner="acme", repo="app", issue=5, branch="b", token="T")
    assert "/work/" not in s
    assert f"export HOME={SANDBOX_ROOT}" in s


def test_task_md_tells_the_agent_how_to_report_a_blocker():
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="T", body="B")
    # The agent must know the sandbox egress is an allowlist, so it reports
    # instead of retrying a fetch that can never succeed.
    assert f"{SANDBOX_ROOT}/BLOCKED.md" in m
    assert f"bash {SANDBOX_ROOT}/report-blocked.sh" in m
    assert "issue #9" in m


def test_task_md_never_carries_the_token():
    # The per-run token reaches the sandbox out-of-band and never passes through
    # the model; the blocker helper reads it from the guest environment.
    m = _task_md(owner="acme", repo="app", issue=9, branch="b", title="T", body="B")
    assert "GITEA_TOKEN" not in m
    assert "token" not in inspect.signature(_task_md).parameters


def test_report_blocked_script_posts_to_the_issue():
    s = _report_blocked_script(owner="acme", repo="app", issue=9)
    assert "/api/v1/repos/acme/app/issues/9/comments" in s
    assert "token $GITEA_TOKEN" in s   # from the env, not interpolated
    assert "json.dumps" in s           # safe escaping of arbitrary error text
    assert f"{SANDBOX_ROOT}/.blocked-posted" in s


def test_run_script_falls_back_when_the_agent_does_not_report():
    s = _run_script(owner="acme", repo="app", issue=5, branch="agent/issue-5", token="T")
    # Claude's own status, not the pipeline's — a crashed session must not look
    # like a clean "no changes" run.
    assert "CLAUDE_RC=${PIPESTATUS[0]}" in s
    assert f"if [ ! -f {SANDBOX_ROOT}/.blocked-posted ]; then" in s
    assert f"bash {SANDBOX_ROOT}/report-blocked.sh" in s
    assert f"tail -n 40 {SANDBOX_ROOT}/claude.log" in s


def test_stream_filter_renders_events_and_survives_garbage():
    events = "\n".join([
        json.dumps({"type": "system", "subtype": "init", "model": "claude-sonnet"}),
        "not json at all",
        json.dumps({"type": "assistant", "message": {"content": [
            {"type": "text", "text": "Reading the repo."},
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/work/repo/app.py"}},
        ]}}),
        json.dumps({"type": "result", "subtype": "success", "num_turns": 7}),
    ])
    out = subprocess.run([sys.executable, "-c", STREAM_FILTER_PY],
                         input=events, capture_output=True, text=True, timeout=30)
    assert out.returncode == 0
    assert "[claude] session start (model claude-sonnet)" in out.stdout
    assert "[claude] Reading the repo." in out.stdout
    assert "[claude] tool Edit: /work/repo/app.py" in out.stdout
    assert "[claude] done: success (7 turns)" in out.stdout
