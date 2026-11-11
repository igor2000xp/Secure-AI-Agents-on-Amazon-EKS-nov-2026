"""Pure webhook logic: HMAC verification + trigger filtering. No I/O."""

import hashlib
import hmac

# Gitea `issues` webhook actions that start a run: ONLY label changes, so the
# agent runs exactly once when the trigger label is added. Creating an issue
# *with* the label fires both `opened` and a label event, so triggering on
# `opened` too would double-run the same issue; adding the label later fires
# only the label event. ("labeled" is the GitHub-style name, kept as a fallback.)
TRIGGER_ACTIONS = {"label_updated", "labeled"}


def verify_signature(secret: str, body: bytes, signature: str | None) -> bool:
    """Constant-time check of Gitea's X-Gitea-Signature (HMAC-SHA256 hex)."""
    if not signature:
        return False
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature)


def should_trigger(payload: dict, *, trigger_label: str, bot_user: str) -> bool:
    """True only for a non-bot, label-change event on an issue carrying the opt-in label.

    Fires only on label-change actions (see TRIGGER_ACTIONS) when the issue
    currently has the trigger label — so creating an issue with the label runs
    exactly once (the paired `opened` event is ignored). Loop guard: skip if
    either the issue author OR the webhook sender (actor) is the bot.

    Note: because it keys on label *presence*, adding/removing an unrelated label
    on an already-labelled issue re-fires. That's acceptable here — a re-run
    force-updates the same `agent/issue-N` branch and the PR-create is idempotent
    (fails harmlessly if the PR exists), so no duplicate PRs result.
    """
    if payload.get("action") not in TRIGGER_ACTIONS:
        return False
    sender = (payload.get("sender") or {}).get("login")
    if sender == bot_user:
        return False
    issue = payload.get("issue") or {}
    author = (issue.get("user") or {}).get("login")
    if author == bot_user:
        return False
    labels = {lbl.get("name") for lbl in (issue.get("labels") or [])}
    return trigger_label in labels
