"""HTTP wrapper so the Chainlit UI can POST queries to this agent.

The MCP server sits behind agentgateway, which authorizes each tool call by the
caller's Cognito persona. The UI forwards the user's Cognito access token as
`Authorization: Bearer`; we build a SESSION-SCOPED agent whose MCP client carries
that token, so tool calls run with the user's identity (see agent.py +
the persona-authz design). Each participant has their own pod, so this cache is
effectively single-user.
"""

import base64
import json
import os

from fastapi import FastAPI, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from agent import build_session_agent, langfuse

# Charts come back through the agent-sandbox MCP server's `download_file` tool
# (module 900), which returns the PNG as a base64 string in its tool result. We
# pull those bytes out of the stream and re-emit them to the UI as an `image`
# SSE event, so the participant sees the chart inline instead of a wall of
# base64 in the transcript.
#
# NOTE: unlike the previous broker, which handed the model only an opaque
# chart_id, the base64 here HAS already passed through the model's context —
# that is the tradeoff of driving a generic sandbox API rather than a
# purpose-built one. This code is only about rendering, not about keeping the
# image away from the LLM. Inert in labs that wire in no sandbox tools.


def _persona_from_token(access_token: str | None) -> str | None:
    """Extract the persona (first cognito:groups entry) from the Cognito access
    token, for Langfuse userId attribution. Best-effort: decode the JWT payload
    WITHOUT verifying the signature (agentgateway already verified it upstream;
    this is only for a trace label). Returns None if unavailable.
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


# A base64 PNG, as returned by download_file. Guards against treating an
# ordinary text file's contents as an image: PNGs start with the 8-byte magic
# \x89PNG\r\n\x1a\n, which base64-encodes to this prefix.
_PNG_B64_PREFIX = "iVBORw0KGgo"


def _image_b64_from_result(result: dict) -> str | None:
    """Pull a base64 PNG out of one toolResult's content, if present.

    download_file returns a dict, which FastMCP serializes into the toolResult
    content as EITHER a {"json": {...}} block (structured content) OR a
    {"text": "<json>"} block — so we check both shapes. Returns the first
    base64 PNG found, else None. Pure + defensive: never raises.
    """
    content = result.get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if not isinstance(block, dict):
            continue
        payload = block.get("json")
        if not isinstance(payload, dict):
            text = block.get("text")
            if isinstance(text, str):
                try:
                    parsed = json.loads(text)
                    payload = parsed if isinstance(parsed, dict) else None
                except (json.JSONDecodeError, TypeError):
                    payload = None
        if isinstance(payload, dict):
            # download_file names the payload "content"; accept a couple of
            # plausible aliases so a tool-shape change does not silently stop
            # rendering charts.
            for key in ("content", "data", "file_content"):
                val = payload.get(key)
                if isinstance(val, str) and val.startswith(_PNG_B64_PREFIX):
                    return val
    return None


def chart_images_from_event(event: dict) -> list[str]:
    """Return base64 PNGs carried by a Strands stream event, in order.

    Mirrors the toolResult walk in sse_events_for. Kept separate (and pure) so
    generate() stays readable. Defensive: [] on any odd shape.
    """
    try:
        msg = event.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "user":
            return []
        content = msg.get("content")
        if not isinstance(content, list):
            return []
        ids = []
        for block in content:
            result = block.get("toolResult") if isinstance(block, dict) else None
            if isinstance(result, dict):
                img = _image_b64_from_result(result)
                if img:
                    ids.append(img)
        return ids
    except Exception:
        return []


def chart_image_event(image_b64: str) -> str | None:
    """Wrap a base64 PNG from download_file as an `image` SSE line.

    No network call: the bytes already arrived in the tool result. Validates by
    decoding, so a truncated or non-image payload is skipped rather than handed
    to the browser. Best-effort — the text answer already stands without it.
    """
    try:
        raw = base64.b64decode(image_b64, validate=True)
        if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
            return None
        payload = {"image": {"base64": image_b64, "mime": "image/png"}}
        return f"data: {json.dumps(payload)}\n\n"
    except Exception:
        print("[chart] discarded a download_file payload that was not a PNG", flush=True)
        return None


class ChatRequest(BaseModel):
    query: str
    session_id: str | None = None
    actor_id: str | None = None


app = FastAPI()

# Session-scoped agents keyed by session_id. Value: (agent, mcp_clients, token).
# The MCP clients (one per MCP_SERVER_URLS endpoint) are entered once per session
# (each lists tools once), not per request.
_sessions: dict[str, tuple] = {}


def _get_session_agent(session_id: str | None, access_token: str | None):
    """Return the agent for this session, (re)building if the token changed.

    Rebuild-on-token-change guards the (rare, single-user) case of a new login
    reusing a session id — the MCP client's bearer is fixed at connect, so a
    changed token needs a fresh client. The session_id + persona are passed as
    Langfuse trace attributes (see build_session_agent).
    """
    key = session_id or "default"
    existing = _sessions.get(key)
    if existing and existing[2] == access_token:
        return existing[0]
    if existing:
        # token changed → tear down the stale clients before rebuilding.
        for c in existing[1]:
            try:
                c.__exit__(None, None, None)
            except Exception:
                pass
    agent, mcp_clients = build_session_agent(
        access_token,
        session_id=session_id,
        user_id=_persona_from_token(access_token),
    )
    _sessions[key] = (agent, mcp_clients, access_token)
    return agent


@app.get("/healthz")
def healthz():
    return {"ok": True}


def _has_401(exc: BaseException) -> bool:
    """True if a 401 / expired-token failure appears anywhere in exc's chain.

    Strands wraps the underlying httpx 401 (agentgateway rejecting an expired
    Cognito token) in an MCPClientInitializationError around an ExceptionGroup,
    so the top-level message never mentions 401 — walk causes, contexts, and any
    ExceptionGroup members to find it.
    """
    seen: set[int] = set()
    stack: list[BaseException] = [exc]
    while stack:
        e = stack.pop()
        if id(e) in seen:
            continue
        seen.add(id(e))
        text = str(e)
        if "401" in text or "Unauthorized" in text or "ExpiredSignature" in text:
            return True
        resp = getattr(e, "response", None)
        if resp is not None and getattr(resp, "status_code", None) == 401:
            return True
        if e.__cause__:
            stack.append(e.__cause__)
        if e.__context__:
            stack.append(e.__context__)
        stack.extend(getattr(e, "exceptions", None) or [])
    return False


def _agent_init_error_message(exc: Exception) -> str:
    """User-facing text when the session agent can't connect its MCP tools."""
    if _has_401(exc):
        return (
            "Your session has expired, so I couldn't reach my tools. Please sign "
            "out and sign back in (a fresh browser window helps), then try again."
        )
    return "I couldn't reach my tools right now. Please try again in a moment."


@app.post("/chat")
async def chat(req: ChatRequest, authorization: str | None = Header(default=None)):
    # Extract the forwarded Cognito bearer (if any).
    access_token = None
    if authorization and authorization.lower().startswith("bearer "):
        access_token = authorization[7:]
    print(
        f"[chat] actor={req.actor_id} session={req.session_id} "
        f"token={'yes' if access_token else 'no'} query={req.query!r}",
        flush=True,
    )

    async def generate():
        # Build the session agent HERE, inside the stream, so a failure to
        # connect or authenticate to the MCP server (e.g. an expired Cognito
        # token → agentgateway 401) becomes a friendly message on a 200 stream,
        # rather than an unhandled exception that 500s /chat and leaves the UI
        # blank.
        try:
            agent = _get_session_agent(req.session_id, access_token)
        except Exception as exc:
            print(f"[chat] session agent init failed: {exc!r}", flush=True)
            yield f"data: {json.dumps({'token': _agent_init_error_message(exc)})}\n\n"
            yield "data: [DONE]\n\n"
            return
        async for event in agent.stream_async(req.query):
            for line in sse_events_for(event):
                yield line
            # A tool result may carry a base64 PNG (download_file). Re-emit it
            # as an `image` event right after its tool_result, so the chart
            # renders under the step that produced it instead of appearing as
            # base64 in the transcript.
            for image_b64 in chart_images_from_event(event):
                image_line = chart_image_event(image_b64)
                if image_line:
                    yield image_line
        langfuse.flush()
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
