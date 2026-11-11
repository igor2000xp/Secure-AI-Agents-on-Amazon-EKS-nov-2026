"""Unit tests for StreamRenderer — the SSE-event -> UI-action dispatcher.

Chainlit-free: the renderer calls an injected `ui` object; tests use FakeUI to
record calls. This keeps app.py's on_message glue trivial.
"""

import sys
import types

# app.py imports chainlit + httpx at module level; stub both so the renderer
# is importable without the chainlit runtime.
sys.modules.setdefault("chainlit", types.SimpleNamespace(
    oauth_callback=lambda f: f,
    on_chat_start=lambda f: f, on_message=lambda f: f,
    User=object, Message=object, Step=object,
    user_session=types.SimpleNamespace(get=lambda *a: None, set=lambda *a: None),
))
sys.modules.setdefault("httpx", types.SimpleNamespace())

import asyncio

from app import StreamRenderer


class FakeUI:
    """Records renderer actions; async methods mirror the UIActions protocol."""

    def __init__(self):
        self.calls = []

    async def stream_answer_token(self, text):
        self.calls.append(("token", text))

    async def open_step(self, key, name, kind):
        self.calls.append(("open", key, name, kind))

    async def update_step_content(self, key, content):
        self.calls.append(("content", key, content))

    async def close_step(self, key, is_error):
        self.calls.append(("close", key, is_error))

    async def end_answer_segment(self):
        self.calls.append(("end_segment",))

    async def render_image(self, b64, mime):
        self.calls.append(("image", b64, mime))


def run(coro):
    return asyncio.run(coro)


def make():
    ui = FakeUI()
    return StreamRenderer(ui), ui


def test_token_streams_to_answer():
    r, ui = make()
    run(r.handle({"token": "Hello"}))
    assert ui.calls == [("token", "Hello")]


def test_reasoning_opens_thinking_step_once_and_accumulates():
    r, ui = make()
    run(r.handle({"reasoning": "user wants "}))
    run(r.handle({"reasoning": "Q1 sales"}))
    assert ui.calls == [
        ("open", "__thinking__", "Thinking", "reasoning"),
        ("content", "__thinking__", "user wants "),
        ("content", "__thinking__", "user wants Q1 sales"),
    ]


def test_non_reasoning_event_closes_thinking_step():
    r, ui = make()
    run(r.handle({"reasoning": "hmm"}))
    run(r.handle({"token": "Answer"}))
    assert ("close", "__thinking__", False) in ui.calls
    # and reasoning can reopen as a NEW burst afterwards
    run(r.handle({"reasoning": "more"}))
    assert ui.calls.count(("open", "__thinking__", "Thinking", "reasoning")) == 2


def test_tool_use_opens_step_and_replaces_input():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "python3"}}))
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "python3 main.py"}}))
    opens = [c for c in ui.calls if c[0] == "open"]
    assert opens == [("open", "t1", "run in the sandbox (execute_command)", "tool")]
    # input REPLACED (accumulated upstream), not concatenated
    assert ui.calls[-1] == ("content", "t1", "```bash\npython3 main.py\n```")


def test_known_tool_uses_friendly_label_with_tool_name():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "ask_order_agent", "input": "x"}}))
    opens = [c for c in ui.calls if c[0] == "open"]
    assert opens == [("open", "t1", "the order specialist (ask_order_agent)", "tool")]


def test_unknown_tool_uses_raw_name_as_label():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t9", "name": "mystery_tool", "input": "x"}}))
    opens = [c for c in ui.calls if c[0] == "open"]
    assert opens == [("open", "t9", "mystery_tool", "tool")]


def test_non_python_tool_input_pretty_printed_json():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t2", "name": "lookup_order", "input": '{"order_id": "ORD-1001"}'}}))
    assert ui.calls[-1] == ("content", "t2", '```json\n{\n  "order_id": "ORD-1001"\n}\n```')


def test_non_python_tool_non_json_input_falls_back_to_raw():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t3", "name": "lookup_order", "input": "partial{"}}))
    assert ui.calls[-1] == ("content", "t3", "```json\npartial{\n```")


def test_tool_result_closes_matching_step():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x=1"}}))
    run(r.handle({"tool_result": {"id": "t1", "status": "success"}}))
    assert ui.calls[-1] == ("close", "t1", False)


def test_tool_result_error_status():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x=1"}}))
    run(r.handle({"tool_result": {"id": "t1", "status": "error"}}))
    assert ui.calls[-1] == ("close", "t1", True)


def test_tool_result_for_unknown_id_is_ignored():
    r, ui = make()
    run(r.handle({"tool_result": {"id": "ghost", "status": "success"}}))
    assert ui.calls == []


def test_unknown_event_keys_ignored():
    r, ui = make()
    run(r.handle({"future_thing": 123}))
    assert ui.calls == []


def test_malformed_events_never_raise():
    r, ui = make()
    run(r.handle({"tool_use": "not-a-dict"}))
    run(r.handle({"tool_result": "oops"}))
    run(r.handle({"reasoning": None}))
    # {"reasoning": None} still lazily opens the thinking step (value coerced
    # to ""); the point is no exception escapes and no TOOL step ever opens.
    assert not any(c[0] == "open" and c[3] == "tool" for c in ui.calls)


def test_two_tool_steps_open_concurrently():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "a", "name": "ask_order_agent", "input": "q1"}}))
    run(r.handle({"tool_use": {"id": "b", "name": "ask_product_agent", "input": "q2"}}))
    run(r.handle({"tool_use": {"id": "a", "name": "ask_order_agent", "input": "q1 more"}}))
    run(r.handle({"tool_result": {"id": "b", "status": "success"}}))
    run(r.handle({"tool_result": {"id": "a", "status": "success"}}))
    opens = [c for c in ui.calls if c[0] == "open"]
    assert opens == [
        ("open", "a", "the order specialist (ask_order_agent)", "tool"),
        ("open", "b", "the product specialist (ask_product_agent)", "tool"),
    ]
    assert ("close", "b", False) in ui.calls and ("close", "a", False) in ui.calls


def test_step_after_tokens_ends_answer_segment():
    # Mid-loop commentary then a tool call: the segment must END so the step
    # (and any later text) renders below the commentary, in true order.
    r, ui = make()
    run(r.handle({"token": "Let me try again."}))
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x"}}))
    assert ui.calls.index(("end_segment",)) < ui.calls.index(
        ("open", "t1", "run in the sandbox (execute_command)", "tool")
    )


def test_step_before_any_tokens_does_not_end_segment():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x"}}))
    assert ("end_segment",) not in ui.calls


def test_reasoning_after_tokens_ends_answer_segment():
    r, ui = make()
    run(r.handle({"token": "So far..."}))
    run(r.handle({"reasoning": "hmm"}))
    assert ui.calls.index(("end_segment",)) < ui.calls.index(
        ("open", "__thinking__", "Thinking", "reasoning")
    )


def test_segment_ends_once_per_text_burst():
    # token -> step (end #1) -> step input updates -> token -> step (end #2):
    # updates to an ALREADY-OPEN step never end a segment, only new steps
    # after new text do.
    r, ui = make()
    run(r.handle({"token": "a"}))
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x"}}))
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "xy"}}))
    run(r.handle({"token": "b"}))
    run(r.handle({"tool_use": {"id": "t2", "name": "execute_command", "input": "z"}}))
    assert ui.calls.count(("end_segment",)) == 2


def test_finish_ends_trailing_answer_segment():
    r, ui = make()
    run(r.handle({"token": "final answer"}))
    run(r.finish(errored=False))
    assert ui.calls[-1] == ("end_segment",)
    # idempotent
    run(r.finish(errored=False))
    assert ui.calls.count(("end_segment",)) == 1


def test_finish_without_tokens_does_not_end_segment():
    r, ui = make()
    run(r.finish(errored=False))
    assert ui.calls == []


def test_upload_file_shows_uploaded_python_as_code():
    # The interesting part of upload_file is the payload, not the envelope:
    # show the uploaded analysis code as real Python, titled with its path.
    r, ui = make()
    raw = '{"path": "main.py", "content": "import pandas as pd\\nprint(1)"}'
    run(r.handle({"tool_use": {"id": "t1", "name": "upload_file", "input": raw}}))
    assert ui.calls[-1] == (
        "content", "t1",
        "`main.py`\n\n```python\nimport pandas as pd\nprint(1)\n```",
    )


def test_upload_file_json_payload_is_fenced_as_json():
    r, ui = make()
    raw = '{"path": "orders.json", "content": "[{\\"order_id\\": \\"ORD-1\\"}]"}'
    run(r.handle({"tool_use": {"id": "t1", "name": "upload_file", "input": raw}}))
    assert ui.calls[-1][2].startswith("`orders.json`\n\n```json\n")


def test_upload_file_binary_payload_is_not_rendered_as_code():
    # A base64 upload would be a screenful of noise; fall back to the envelope.
    r, ui = make()
    raw = '{"path": "x.png", "content": "iVBORw0KGgo=", "binary": true}'
    run(r.handle({"tool_use": {"id": "t1", "name": "upload_file", "input": raw}}))
    assert ui.calls[-1][2].startswith("```json\n")


def test_upload_file_partial_json_input_falls_back_to_raw():
    r, ui = make()
    run(r.handle({"tool_use": {"id": "t1", "name": "upload_file", "input": '{"path": "main.py", "cont'}}))
    assert ui.calls[-1] == ("content", "t1", '```json\n{"path": "main.py", "cont\n```')


def test_execute_command_shows_the_bare_command():
    r, ui = make()
    raw = '{"sandbox_claim_name": "c-1", "command": "python3 main.py"}'
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": raw}}))
    assert ui.calls[-1] == ("content", "t1", "```bash\npython3 main.py\n```")


def test_image_event_renders_image():
    r, ui = make()
    run(r.handle({"image": {"base64": "QUJD", "mime": "image/png"}}))
    assert ("image", "QUJD", "image/png") in ui.calls


def test_image_event_defaults_mime_when_absent():
    r, ui = make()
    run(r.handle({"image": {"base64": "QUJD"}}))
    assert ("image", "QUJD", "image/png") in ui.calls


def test_image_after_tokens_ends_answer_segment_first():
    # A chart arriving mid-answer must end the current text segment so it renders
    # below the commentary, in chronological order (same rule as steps).
    r, ui = make()
    run(r.handle({"token": "Here is the chart:"}))
    run(r.handle({"image": {"base64": "QUJD", "mime": "image/png"}}))
    assert ui.calls.index(("end_segment",)) < ui.calls.index(("image", "QUJD", "image/png"))


def test_image_without_base64_is_ignored():
    r, ui = make()
    run(r.handle({"image": {"mime": "image/png"}}))
    run(r.handle({"image": {"base64": ""}}))
    assert not any(c[0] == "image" for c in ui.calls)


def test_malformed_image_event_never_raises():
    r, ui = make()
    run(r.handle({"image": "not-a-dict"}))
    run(r.handle({"image": None}))
    assert not any(c[0] == "image" for c in ui.calls)


def test_finish_closes_all_open_steps():
    r, ui = make()
    # tool_use first, THEN reasoning — both stay open together (a tool_use
    # arriving after reasoning would close the thinking step, by design)
    run(r.handle({"tool_use": {"id": "t1", "name": "execute_command", "input": "x"}}))
    run(r.handle({"reasoning": "hmm"}))
    run(r.finish(errored=True))
    closes = [c for c in ui.calls if c[0] == "close"]
    assert ("close", "__thinking__", True) in closes
    assert ("close", "t1", True) in closes
    # idempotent: second finish closes nothing further
    n = len(ui.calls)
    run(r.finish(errored=True))
    assert len(ui.calls) == n
