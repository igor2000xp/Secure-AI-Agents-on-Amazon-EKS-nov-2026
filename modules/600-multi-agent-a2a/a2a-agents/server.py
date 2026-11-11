"""HTTP wrapper so the Chainlit UI can POST queries to the A2A orchestrator.

The UI forwards the user's Cognito access token as `Authorization: Bearer`. We
decode its persona (cognito:groups) and pass it — plus the request session_id —
as Strands trace attributes on the orchestrator, so the shared multi-agent trace
is labelled by conversation and persona instead of a bare `POST /chat`. The same
token is also handed to the A2A tool calls via the _access_token ContextVar (see
orchestrator). Each participant has their own pod, so this session cache is
effectively single-user.
"""

import base64
import json
import os

from fastapi import FastAPI, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from orchestrator import build_session_agent, langfuse, _access_token


def _persona_from_token(access_token: str | None) -> str | None:
    """Extract the persona (first cognito:groups entry) from the Cognito access
    token, for Langfuse userId attribution. Best-effort: decode the JWT payload
    WITHOUT verifying the signature (this is only for a trace label). Returns
    None if unavailable.
    """
    if not access_token:
        return None
    try:
        payload = access_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # pad to a multiple of 4
        claims = json.loads(base64.urlsafe_b64decode(payload))
        groups = claims.get("cognito:groups") or []
        return groups[0] if groups else claims.get("username")
    except Exception:
        return None


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

# Session-scoped orchestrators keyed by session_id. Value: (agent, token). The
# agent carries the session_id + persona as Langfuse trace attributes, which are
# fixed at construction — so we cache one per session and rebuild if a new login
# reuses the same session id (rare, single-user) with a different persona.
_sessions: dict[str, tuple] = {}


def _get_session_agent(session_id: str | None, access_token: str | None):
    key = session_id or "default"
    existing = _sessions.get(key)
    if existing and existing[1] == access_token:
        return existing[0]
    agent = build_session_agent(
        session_id=session_id,
        user_id=_persona_from_token(access_token),
    )
    _sessions[key] = (agent, access_token)
    return agent


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest, authorization: str | None = Header(default=None)):
    # Forward the UI's Cognito bearer to the A2A tool calls via the ContextVar
    # (orchestrator._access_token). Strands propagates context into tool
    # execution, so the token reaches ask_order_agent/_ask on each request.
    access_token = None
    if authorization and authorization.lower().startswith("bearer "):
        access_token = authorization[7:]
    _access_token.set(access_token)

    print(
        f"[chat] actor={req.actor_id} session={req.session_id} "
        f"token={'yes' if access_token else 'no'} query={req.query!r}",
        flush=True,
    )

    agent = _get_session_agent(req.session_id, access_token)

    async def generate():
        async for event in agent.stream_async(req.query):
            for line in sse_events_for(event):
                yield line
        langfuse.flush()
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8083")))
