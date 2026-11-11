"""Unit tests for server.py's SSE mapper + chart helpers.

Pure-dict logic throughout: no strands and no network at all. server.py does
`from agent import ...` (pulls in strands, not installed for unit tests), so we
stub `agent`. Charts now arrive as base64 inside a download_file tool result
rather than being fetched over HTTP, so these tests need no socket and no
monkey-patched client.
"""

import sys
import types

# Stub the agent module server.py imports at load time.
sys.modules.setdefault(
    "agent",
    types.SimpleNamespace(build_session_agent=lambda *a, **k: (None, []), langfuse=None),
)

import asyncio
import json

import server
from server import sse_events_for, chart_images_from_event, chart_image_event


def _parse(lines):
    out = []
    for line in lines:
        assert line.startswith("data: ") and line.endswith("\n\n")
        out.append(json.loads(line[len("data: "):]))
    return out


def run(coro):
    return asyncio.run(coro)


# --- sse_events_for: unchanged behavior still holds -------------------------

def test_text_delta_maps_to_token():
    assert _parse(sse_events_for({"data": "Hello"})) == [{"token": "Hello"}]


def test_tool_result_maps_to_status_event():
    event = {"message": {"role": "user", "content": [
        {"toolResult": {"toolUseId": "t1", "status": "success"}}
    ]}}
    assert _parse(sse_events_for(event)) == [{"tool_result": {"id": "t1", "status": "success"}}]


# --- chart_images_from_event ------------------------------------------------

# A real 1x1 PNG, so the magic-byte checks in server.py are exercised rather
# than mocked.
import base64 as _b64

_PNG_1X1 = _b64.b64encode(
    bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
        "0000000a49444154789c6300010000050001"
        "0d0a2db40000000049454e44ae426082"
    )
).decode("ascii")


def _tool_result_event(content):
    return {"message": {"role": "user", "content": [{"toolResult": {
        "toolUseId": "t1", "status": "success", "content": content,
    }}]}}


def test_image_from_json_content_block():
    ev = _tool_result_event([{"json": {"content": _PNG_1X1, "bytes_read": 70}}])
    assert chart_images_from_event(ev) == [_PNG_1X1]


def test_image_from_text_json_content_block():
    ev = _tool_result_event([{"text": json.dumps({"content": _PNG_1X1})}])
    assert chart_images_from_event(ev) == [_PNG_1X1]


def test_non_png_download_is_ignored():
    """download_file is generic: reading orders.json back must not render."""
    text_b64 = _b64.b64encode(b'{"order_id": "ORD-1"}').decode("ascii")
    ev = _tool_result_event([{"json": {"content": text_b64, "bytes_read": 21}}])
    assert chart_images_from_event(ev) == []


def test_no_image_returns_empty():
    ev = _tool_result_event([{"json": {"stdout": "ok", "exit_code": 0}}])
    assert chart_images_from_event(ev) == []


def test_image_ignores_non_json_text():
    ev = _tool_result_event([{"text": "just some stdout, not json"}])
    assert chart_images_from_event(ev) == []


def test_image_non_tool_result_event_is_empty():
    assert chart_images_from_event({"data": "hi"}) == []
    assert chart_images_from_event({"message": {"role": "assistant", "content": []}}) == []


def test_image_malformed_never_raises():
    assert chart_images_from_event({"message": "nope"}) == []
    assert chart_images_from_event({"message": {"role": "user", "content": "x"}}) == []


# --- chart_image_event ------------------------------------------------------

def test_chart_image_event_wraps_a_png():
    line = chart_image_event(_PNG_1X1)
    assert line is not None
    assert _parse([line]) == [{"image": {"base64": _PNG_1X1, "mime": "image/png"}}]


def test_chart_image_event_rejects_non_png():
    assert chart_image_event(_b64.b64encode(b"not a png").decode("ascii")) is None


def test_chart_image_event_rejects_invalid_base64():
    assert chart_image_event("!!! not base64 !!!") is None
