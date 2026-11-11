"""Workshop chat UI.

Single agent: every message HTTP-POSTs to the in-cluster `customer-agent`
Service. The single-agent labs all redeploy that same Service, so which lab's
code answers depends on what you last deployed. Session IDs stay stable per
browser session.
"""

import asyncio
import base64
import json
import os
import uuid

import chainlit as cl
import httpx

# The one agent this UI talks to. The default matches every lab's k8s.yaml;
# AGENT_URL overrides it if the Service ever moves.
AGENT_URL = os.environ.get(
    "AGENT_URL", "http://customer-agent.default.svc.cluster.local:8080/chat"
)

REQUEST_TIMEOUT = 120  # seconds


# Human-readable labels for the retail personas (Cognito group -> display name).
PERSONA_LABELS = {
    "sales-analyst": "Sales Analyst",
    "support-associate": "Support Associate",
}


def _jwt_claims(jwt_token: str) -> dict:
    """Decode a JWT payload WITHOUT verifying the signature.

    Safe here: the token was just minted by Cognito and handed to us by
    Chainlit over the server-side code exchange — we're only reading a claim
    for display, not making a trust decision. Returns {} on any malformed
    input so a bad token can never break the login gate.
    """
    try:
        payload_b64 = jwt_token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)  # restore padding
        return json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception:
        return {}


def _log_auth(claims: dict, groups: list, persona, source: str) -> None:
    """Log a decoded-claims SUMMARY to stdout for workshop debugging.

    Visible via `kubectl logs deploy/chainlit-ui`. Deliberately a summary (not
    the full JWT or raw token): the fields that show whether the
    `cognito:groups` claim propagated into a persona. `groups` is the EFFECTIVE
    list actually used to derive the persona (so it stays consistent with
    persona regardless of source). `source` reports WHERE the claim came from —
    `token` proves it was read from the Cognito ID/access token (the reliable
    path), vs `userInfo` (which does NOT carry cognito:groups) or `none`
    (propagation broken). Reads everything via .get() so a missing claim logs as
    None/[] and never raises.
    """
    print(
        f"[auth] user={claims.get('cognito:username') or claims.get('username')} "
        f"groups={groups} persona={persona} "
        f"token_use={claims.get('token_use')} exp={claims.get('exp')} "
        f"claim_source={source}",
        flush=True,
    )


THINKING_KEY = "__thinking__"

# Friendly step labels keyed by tool name. Chainlit's frontend prepends
# "Using …" / "Used …", so these read as "Used order lookup (lookup_order)".
# The tool name stays in parentheses because this is a workshop about building
# agents — participants should still see which tool fired. Unknown tools fall
# back to the raw name.
TOOL_LABELS = {
    # agent-sandbox MCP tools (module 900). An analysis run fires five of these
    # in sequence, so the labels say what each step is FOR rather than repeating
    # "sandbox" five times.
    "create_sandbox": "claim a sandbox (create_sandbox)",
    "upload_file": "send to the sandbox (upload_file)",
    "execute_command": "run in the sandbox (execute_command)",
    "download_file": "fetch from the sandbox (download_file)",
    "delete_sandbox": "release the sandbox (delete_sandbox)",
    "get_sandbox_status": "sandbox status (get_sandbox_status)",
    "get_orders": "orders query (get_orders)",
    "lookup_order": "order lookup (lookup_order)",
    "check_inventory": "inventory check (check_inventory)",
    "initiate_return": "return request (initiate_return)",
    "ask_order_agent": "the order specialist (ask_order_agent)",
    "ask_product_agent": "the product specialist (ask_product_agent)",
}


def _tool_step_body(name: str, raw_input: str) -> str:
    """Render a tool's accumulated input as a fenced code block.

    Two special cases keep the sandbox flow readable, because the interesting
    part of those calls is a payload nested inside the JSON args:

      upload_file     — show the uploaded `content` as Python when it looks like
                        the analysis code. This is how a participant sees what
                        the model actually wrote.
      execute_command — show the bare `command`, not a JSON wrapper.

    A base64 upload (the model sending binary) is NOT rendered as code: it would
    be a screenful of noise. Everything else pretty-prints its JSON args, or
    falls back to the raw text while the input is still streaming.
    """
    if name == "upload_file":
        try:
            parsed = json.loads(raw_input)
            if isinstance(parsed, dict):
                content = parsed.get("content")
                path = parsed.get("path") or ""
                if isinstance(content, str) and not parsed.get("binary"):
                    lang = "python" if path.endswith(".py") else "json" if path.endswith(".json") else ""
                    header = f"`{path}`\n\n" if path else ""
                    return f"{header}```{lang}\n{content}\n```"
        except (json.JSONDecodeError, TypeError):
            pass
        return f"```json\n{raw_input}\n```"

    if name == "execute_command":
        try:
            parsed = json.loads(raw_input)
            if isinstance(parsed, dict) and isinstance(parsed.get("command"), str):
                return f"```bash\n{parsed['command']}\n```"
        except (json.JSONDecodeError, TypeError):
            pass
        return f"```bash\n{raw_input}\n```"

    try:
        parsed = json.loads(raw_input)
        pretty = json.dumps(parsed, indent=2)
        return f"```json\n{pretty}\n```"
    except (json.JSONDecodeError, TypeError):
        return f"```json\n{raw_input}\n```"


class StreamRenderer:
    """Dispatch agent SSE events to UI actions (steps + answer tokens).

    Chainlit-free by design so it unit-tests with a fake: `ui` provides
    stream_answer_token / open_step / update_step_content / close_step /
    end_answer_segment / render_image.
    Wire contract (shared with each lab's server.py sse_events_for):
      token / reasoning are text deltas; tool_use.input is ACCUMULATED-so-far
      (replace, don't concatenate); tool_result closes the step by id;
      image carries {base64, mime} — a chart the agent fetched out-of-band from
      the code-exec broker (module 900), rendered inline below its tool step.

    Answer text is SEGMENTED: when a new step opens after tokens have
    streamed, the current answer message is ended first, so text and steps
    interleave in true chronological order (step -> commentary -> step ->
    final answer) instead of all text pooling in one bubble above the steps.
    """

    def __init__(self, ui):
        self.ui = ui
        self.open_steps: dict[str, bool] = {}  # key -> opened (True until closed)
        self.reasoning_text = ""
        self.answer_pending = False  # tokens streamed since the last segment end

    async def handle(self, event: dict) -> None:
        if "reasoning" not in event:
            await self._close_thinking(errored=False)

        if "token" in event:
            self.answer_pending = True
            await self.ui.stream_answer_token(event["token"])

        elif "reasoning" in event:
            if THINKING_KEY not in self.open_steps:
                await self._end_answer_segment()
                self.open_steps[THINKING_KEY] = True
                self.reasoning_text = ""
                await self.ui.open_step(THINKING_KEY, "Thinking", "reasoning")
            self.reasoning_text += str(event["reasoning"] or "")
            await self.ui.update_step_content(THINKING_KEY, self.reasoning_text)

        elif "tool_use" in event:
            tool = event["tool_use"]
            if not isinstance(tool, dict):
                return
            name = tool.get("name", "tool")
            key = tool.get("id") or name  # id-less tools fall back to name so keys never collide on ""
            if key not in self.open_steps:
                await self._end_answer_segment()
                self.open_steps[key] = True
                await self.ui.open_step(key, TOOL_LABELS.get(name, name), "tool")
            await self.ui.update_step_content(key, _tool_step_body(name, tool.get("input", "")))

        elif "tool_result" in event:
            result = event["tool_result"]
            if not isinstance(result, dict):
                return
            key = result.get("id", "")
            if key in self.open_steps:
                del self.open_steps[key]
                await self.ui.close_step(key, result.get("status") == "error")

        elif "image" in event:
            image = event["image"]
            if not isinstance(image, dict):
                return
            b64 = image.get("base64")
            if not isinstance(b64, str) or not b64:
                return
            # End any in-flight text segment so the chart lands in chronological
            # order (below the tool step that produced it), not pinned above.
            await self._end_answer_segment()
            await self.ui.render_image(b64, image.get("mime", "image/png"))

    async def finish(self, errored: bool) -> None:
        """Close anything still open — called on stream end AND on error paths
        so the UI never shows a spinner forever."""
        await self._close_thinking(errored)
        for key in list(self.open_steps):
            del self.open_steps[key]
            await self.ui.close_step(key, errored)
        await self._end_answer_segment()

    async def _end_answer_segment(self) -> None:
        if self.answer_pending:
            self.answer_pending = False
            await self.ui.end_answer_segment()

    async def _close_thinking(self, errored: bool) -> None:
        if THINKING_KEY in self.open_steps:
            del self.open_steps[THINKING_KEY]
            await self.ui.close_step(THINKING_KEY, errored)


class ChainlitUI:
    """Real UI actions for StreamRenderer, backed by cl.Message + cl.Step.

    Steps are entered manually (not `async with`) because their lifetime spans
    many SSE events; StreamRenderer.finish() guarantees closure on all paths.

    Answer messages are created LAZILY, one per segment: Chainlit anchors an
    element's position in the transcript at creation, so a message sent before
    the stream starts would pin ALL answer text above every step. Creating the
    message on the first token of each segment (and send()ing it when the
    segment ends) keeps text and steps in chronological order.
    """

    def __init__(self):
        self.msg: cl.Message | None = None
        self.steps: dict[str, cl.Step] = {}

    async def stream_answer_token(self, text: str) -> None:
        if self.msg is None:
            self.msg = cl.Message(content="")
        await self.msg.stream_token(text)

    async def end_answer_segment(self) -> None:
        if self.msg is not None:
            await self.msg.send()  # ends streaming + persists this segment
            self.msg = None

    async def open_step(self, key: str, name: str, kind: str) -> None:
        # default_open so the code/args are visible without a click; users can
        # collapse. Chainlit auto-collapses a step once it ends, so this only
        # affects the in-flight view — which is exactly when the detail matters.
        step = cl.Step(
            name=name,
            type="llm" if kind == "reasoning" else "tool",
            default_open=True,
        )
        await step.__aenter__()
        self.steps[key] = step

    async def update_step_content(self, key: str, content: str) -> None:
        step = self.steps.get(key)
        if step is not None:
            step.output = content
            await step.update()

    async def close_step(self, key: str, is_error: bool) -> None:
        step = self.steps.pop(key, None)
        if step is not None:
            if is_error:
                step.is_error = True
            await step.__aexit__(None, None, None)

    async def render_image(self, b64: str, mime: str) -> None:
        # Decode to raw bytes and hand Chainlit a native inline Image element.
        # `display="inline"` shows it in the message flow (not a side drawer).
        # Bad base64 is swallowed: a broken chart must never kill the answer.
        try:
            data = base64.b64decode(b64)
        except (ValueError, TypeError):
            return
        image = cl.Image(content=data, name="chart", display="inline", size="large")
        await cl.Message(content="", elements=[image]).send()


@cl.oauth_callback
def oauth_callback(
    provider_id: str,
    token: str,
    raw_user_data: dict,
    default_user: cl.User,
) -> cl.User | None:
    """Cognito auth gate + persona extraction.

    Chainlit calls this after a successful Cognito Hosted UI login (the
    aws-cognito OAuth provider, configured via the OAUTH_COGNITO_* env vars set
    on the deployment). Returning the user admits them; returning None denies.

    Every user in the pool is a valid workshop participant, so we admit any
    successful login. We also read the `cognito:groups` claim (propagated from
    the user's Cognito group) to derive the retail persona and stash it on the
    user's metadata. Phase 1: this drives UI presentation only — it is NOT an
    enforced authorization boundary.

    NOTE: `cognito:groups` lives in the Cognito ID/access token, NOT in the
    `/oauth2/userInfo` response that Chainlit uses to build `raw_user_data`.
    So we read it from `token` (the access token), which is the reliable
    source, and fall back to `raw_user_data` only in case a future config maps
    the claim there.
    """
    claims = _jwt_claims(token)
    groups = claims.get("cognito:groups") or raw_user_data.get("cognito:groups") or []
    persona = groups[0] if groups else None
    # Which source actually yielded the claim — see _log_auth. cognito:groups
    # lives in the token, NOT the /oauth2/userInfo response Chainlit uses for
    # raw_user_data, so the healthy case is claim_source=token.
    source = (
        "token" if claims.get("cognito:groups")
        else "userInfo" if raw_user_data.get("cognito:groups")
        else "none"
    )
    default_user.metadata["persona"] = persona
    default_user.metadata["persona_label"] = PERSONA_LABELS.get(persona, persona or "Workshop User")
    # Stash the Cognito access token so on_message can forward it to the agent
    # as a bearer. The agent forwards it to agentgateway, which enforces
    # per-tool authz by the cognito:groups claim (700-agentgateway-authz).
    default_user.metadata["access_token"] = token
    _log_auth(claims, groups, persona, source)
    return default_user


@cl.on_chat_start
async def start():
    cl.user_session.set("session_id", f"ui-{uuid.uuid4()}")

    # Surface the retail persona derived from the cognito:groups JWT claim.
    #
    # DISPLAY ONLY: the UI does not decide what the agent can do. Tools are
    # granted per persona at agentgateway, and only from the Securing the agents
    # lab onwards. So this says who you are, and deliberately does NOT name a
    # capability. The previous version told the Sales Analyst that "code
    # execution" was enabled, which is untrue until the Agents using a sandbox
    # lab deploys the sandbox tools, and it gave away the punchline of the
    # authorization lab before the participant got there.
    app_user = cl.user_session.get("user")
    persona_label = app_user.metadata.get("persona_label") if app_user else None
    if persona_label:
        persona_line = (
            f"👤 Signed in as **{persona_label}**. Which tools I can use is "
            "decided per persona at the gateway, so it depends on which labs "
            "you have applied.\n\n"
        )
    else:
        persona_line = ""

    await cl.Message(
        content=(
            "🪴 **AnyCompany Shop Customer Agent**\n\n"
            f"{persona_line}"
            "Ask me something: an order ID, a product question, whatever the lab suggests."
        )
    ).send()


@cl.on_message
async def on_message(message: cl.Message):
    session_id = cl.user_session.get("session_id")

    # Correlate each request to the logged-in persona (set in oauth_callback).
    # Visible via `kubectl logs deploy/chainlit-ui`.
    app_user = cl.user_session.get("user")
    persona = app_user.metadata.get("persona") if app_user else None
    print(
        f"[chat] persona={persona} session={session_id} "
        f"query={message.content!r}",
        flush=True,
    )

    payload = {
        "query": message.content,
        "session_id": session_id,
        "actor_id": "workshop-user",
    }

    # Forward the user's Cognito access token so the agent can propagate it to
    # agentgateway, which enforces per-tool MCP authz by the cognito:groups
    # persona claim (see modules/.../700-agentgateway-authz). No token → the
    # agent simply omits the bearer and the gateway denies (fail-closed).
    headers = {}
    access_token = app_user.metadata.get("access_token") if app_user else None
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"

    # No message is sent up front: ChainlitUI lazily creates one answer
    # message per text segment so steps and text interleave chronologically.
    renderer = StreamRenderer(ChainlitUI())

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        try:
            async with client.stream("POST", AGENT_URL, json=payload, headers=headers) as resp:
                resp.raise_for_status()
                # Drain the stream to its natural end rather than `break`ing on
                # [DONE]: breaking mid-iteration abandons httpx's async-generator
                # chain at a yield, so the GC finalizes it in a different task
                # and httpcore's cancel-scope cleanup logs noisy (harmless)
                # "GeneratorExit"/"cancel scope in a different task" tracebacks.
                # Every agent's generate() returns right after [DONE], so the
                # loop ends immediately and the generators close cleanly here.
                done = False
                async for line in resp.aiter_lines():
                    if done or not line.startswith("data: "):
                        continue
                    data = line[6:]
                    if data == "[DONE]":
                        done = True
                        continue
                    try:
                        await renderer.handle(json.loads(data))
                        await asyncio.sleep(0.03)
                    except json.JSONDecodeError:
                        pass
            await renderer.finish(errored=False)
        except httpx.ConnectError:
            await renderer.finish(errored=True)
            await cl.Message(
                content=(
                    "⚠️ Can't reach the **customer agent**. "
                    "Finish this lab's build and deploy step, then try again."
                )
            ).send()
        except httpx.HTTPStatusError as e:
            await renderer.finish(errored=True)
            await cl.Message(
                content=f"❌ The agent returned {e.response.status_code}: `{e.response.text[:400]}`"
            ).send()
        except Exception as e:
            await renderer.finish(errored=True)
            await cl.Message(content=f"❌ {type(e).__name__}: {e}").send()
