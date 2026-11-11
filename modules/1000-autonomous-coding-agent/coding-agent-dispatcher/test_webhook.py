import hashlib
import hmac

from webhook import verify_signature, should_trigger


def _sign(secret: str, body: bytes) -> str:
    return hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def test_verify_signature_accepts_valid():
    body = b'{"a":1}'
    sig = _sign("s3cret", body)
    assert verify_signature("s3cret", body, sig) is True


def test_verify_signature_rejects_tampered():
    body = b'{"a":1}'
    sig = _sign("s3cret", b'{"a":2}')
    assert verify_signature("s3cret", body, sig) is False


def test_verify_signature_rejects_missing():
    assert verify_signature("s3cret", b"{}", None) is False


def test_should_trigger_true_on_labeled_with_trigger_label():
    payload = {
        "action": "label_updated",
        "issue": {"labels": [{"name": "agent"}], "user": {"login": "workshop-user"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is True


def test_should_trigger_false_without_label():
    payload = {
        "action": "opened",
        "issue": {"labels": [{"name": "bug"}], "user": {"login": "workshop-user"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is False


def test_should_trigger_false_when_bot_authored():
    payload = {
        "action": "opened",
        "issue": {"labels": [{"name": "agent"}], "user": {"login": "coding-agent-bot"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is False


def test_should_trigger_false_on_non_trigger_action():
    # A labelled issue being closed/edited must NOT re-run the agent.
    payload = {
        "action": "closed",
        "issue": {"labels": [{"name": "agent"}], "user": {"login": "workshop-user"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is False


def test_should_trigger_false_when_bot_is_sender():
    # Loop guard on the actor: a bot-driven label event must not re-fire, even
    # on a human-authored issue.
    payload = {
        "action": "label_updated",
        "sender": {"login": "coding-agent-bot"},
        "issue": {"labels": [{"name": "agent"}], "user": {"login": "workshop-user"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is False


def test_should_trigger_false_on_opened_even_with_label():
    # Creating an issue WITH the label fires `opened` + a label event; only the
    # label event should run the agent, so `opened` must not trigger (no double-run).
    payload = {
        "action": "opened",
        "issue": {"labels": [{"name": "agent"}], "user": {"login": "workshop-user"}},
    }
    assert should_trigger(payload, trigger_label="agent", bot_user="coding-agent-bot") is False
