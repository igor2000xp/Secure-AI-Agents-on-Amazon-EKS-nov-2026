"""HTTP wrapper so the Chainlit UI can POST queries to this agent.

Keeps agent.py importable as-is for anyone running from the CLI.
"""

import json
import os

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from agent import build_agent


def sse_events_for(event: dict) -> list[str]:
    """Map one Strands stream_async event to zero-or-more SSE lines.

    Wire contract (shared with modules/ui/app.py — keep in sync):
      {"token": str}        answer text delta
      {"reasoning": str}    model thinking delta (only when the model emits it)
      {"tool_use": {"id", "name", "input"}}   input is ACCUMULATED-so-far
      {"tool_result": {"id", "status"}}       status only; payload stays in Langfuse

    Defensive by design: a malformed event returns [] rather than raising, so
    one odd event never kills the stream mid-answer.
    """
    try:
        if "data" in event:
            return [f"data: {json.dumps({'token': event['data']})}\n\n"]

        if event.get("reasoning") and event.get("reasoningText"):
            return [f"data: {json.dumps({'reasoning': event['reasoningText']})}\n\n"]

        if "current_tool_use" in event:
            tool = event["current_tool_use"]
            if not isinstance(tool, dict) or not tool.get("name"):
                return []
            tool_input = tool.get("input", "")
            if not isinstance(tool_input, str):
                tool_input = json.dumps(tool_input)
            payload = {"tool_use": {"id": tool.get("toolUseId", ""), "name": tool["name"], "input": tool_input}}
            return [f"data: {json.dumps(payload)}\n\n"]

        if "message" in event:
            msg = event["message"]
            if not isinstance(msg, dict) or msg.get("role") != "user":
                return []
            lines = []
            content = msg.get("content")
            if not isinstance(content, list):
                return []
            for block in content:
                result = block.get("toolResult") if isinstance(block, dict) else None
                if result:
                    payload = {"tool_result": {"id": result.get("toolUseId", ""), "status": result.get("status", "success")}}
                    lines.append(f"data: {json.dumps(payload)}\n\n")
            return lines

        return []
    except Exception:
        return []


class ChatRequest(BaseModel):
    query: str
    session_id: str | None = None
    actor_id: str | None = None


app = FastAPI()

# One agent per chat session, keyed by the session id the UI sends.
#
# A Strands Agent keeps the conversation on itself (see agent.py), so a single
# shared agent would carry history across new chats AND across signed-in users.
# Keying by session_id gives each conversation its own history, which is what
# makes "new chat" in the UI actually start fresh.
#
# Deliberately a plain dict with no eviction: one workshop account has a handful
# of sessions, and a restart is a clean slate. A real deployment would bound it
# and move history to a store outside the pod.
_sessions: dict[str, object] = {}


def _get_session_agent(session_id: str | None):
    key = session_id or "default"
    if key not in _sessions:
        _sessions[key] = build_agent()
    return _sessions[key]


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest):
    print(f"[chat] actor={req.actor_id} session={req.session_id} query={req.query!r}", flush=True)

    agent = _get_session_agent(req.session_id)

    async def generate():
        async for event in agent.stream_async(req.query):
            for line in sse_events_for(event):
                yield line
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
