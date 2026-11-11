"""Unit tests for the stream_async -> SSE event mapper in server.py.

Pure-dict logic: no strands or network needed (fastapi/uvicorn must still be
importable — server.py imports them at module level). The fake events below
mirror the shapes documented at strandsagents.com (streaming event reference)
and asserted against the module 900 live flow.
"""

import sys
import types

# server.py does `from agent import build_agent`, which pulls in strands (not
# installed for unit tests). Stub it: the mapper under test never touches it.
sys.modules.setdefault("agent", types.SimpleNamespace(build_agent=lambda: None))

import json

from server import sse_events_for


def _parse(lines):
    """Decode a list of 'data: {json}\\n\\n' SSE lines into dicts."""
    out = []
    for line in lines:
        assert line.startswith("data: ") and line.endswith("\n\n")
        out.append(json.loads(line[len("data: "):]))
    return out


def test_text_delta_maps_to_token():
    assert _parse(sse_events_for({"data": "Hello"})) == [{"token": "Hello"}]


def test_reasoning_delta_maps_to_reasoning():
    events = sse_events_for({"reasoning": True, "reasoningText": "user wants Q1 sales"})
    assert _parse(events) == [{"reasoning": "user wants Q1 sales"}]


def test_reasoning_event_without_text_is_dropped():
    # redactedContent / signature-only reasoning events carry no displayable text
    assert sse_events_for({"reasoning": True, "reasoning_signature": "abc"}) == []


def test_current_tool_use_maps_to_tool_use_with_string_input():
    events = sse_events_for({
        "current_tool_use": {
            "toolUseId": "t1", "name": "execute_command",
            "input": 'python3 main.py',
        }
    })
    assert _parse(events) == [
        {"tool_use": {"id": "t1", "name": "execute_command", "input": "python3 main.py"}}
    ]


def test_current_tool_use_dict_input_is_json_serialized():
    events = sse_events_for({
        "current_tool_use": {
            "toolUseId": "t2", "name": "lookup_order",
            "input": {"order_id": "ORD-1001"},
        }
    })
    parsed = _parse(events)
    assert parsed[0]["tool_use"]["input"] == json.dumps({"order_id": "ORD-1001"})


def test_current_tool_use_without_name_is_dropped():
    # First streamed fragment can arrive before the tool name is known.
    assert sse_events_for({"current_tool_use": {"toolUseId": "t3", "input": ""}}) == []


def test_tool_result_message_maps_to_tool_result():
    events = sse_events_for({
        "message": {
            "role": "user",
            "content": [
                {"toolResult": {"toolUseId": "t1", "status": "success", "content": [{"text": "big payload"}]}}
            ],
        }
    })
    # status only — result content deliberately not forwarded (spec: Langfuse has it)
    assert _parse(events) == [{"tool_result": {"id": "t1", "status": "success"}}]


def test_assistant_message_produces_nothing():
    events = sse_events_for({"message": {"role": "assistant", "content": [{"text": "hi"}]}})
    assert events == []


def test_lifecycle_events_produce_nothing():
    assert sse_events_for({"init_event_loop": True}) == []
    assert sse_events_for({"event": {"contentBlockDelta": {}}}) == []


def test_data_takes_priority_and_is_exclusive():
    # A single stream_async event only ever maps to one SSE line per concern;
    # 'data' present means it's a text delta even if lifecycle keys ride along.
    events = sse_events_for({"data": "hi", "reasoning": True, "reasoningText": "x"})
    assert _parse(events) == [{"token": "hi"}]


def test_malformed_event_never_raises():
    # Defensive: one odd event must not kill the SSE stream (spec: error handling)
    assert sse_events_for({"current_tool_use": "not-a-dict"}) == []
    assert sse_events_for({"message": {"role": "user", "content": "not-a-list"}}) == []
    assert sse_events_for({}) == []
    assert sse_events_for(None) == []
    assert sse_events_for({"data": object()}) == []


def test_mapper_is_byte_identical_across_labs():
    """Each lab's server.py is a self-contained teaching copy. This guards the
    sse_events_for copies from drifting apart."""
    import ast
    import pathlib

    here = pathlib.Path(__file__).resolve()
    root = here.parents[2]  # -> modules
    servers = [
        here.parent / "server.py",
        root / "300-observability-langfuse/customer-agent/server.py",
        root / "500-agent-tools-mcp/customer-agent/server.py",
        root / "600-multi-agent-a2a/a2a-agents/server.py",
    ]

    def mapper_source(path):
        source = path.read_text()
        tree = ast.parse(source)
        fn = next((n for n in ast.walk(tree)
                   if isinstance(n, ast.FunctionDef) and n.name == "sse_events_for"), None)
        assert fn is not None, f"sse_events_for missing in {path}"
        return ast.get_source_segment(source, fn)

    sources = {p: mapper_source(p) for p in servers}
    baseline = sources[servers[0]]
    for path, src in sources.items():
        assert src == baseline, f"sse_events_for in {path} drifted from module 200's copy"
