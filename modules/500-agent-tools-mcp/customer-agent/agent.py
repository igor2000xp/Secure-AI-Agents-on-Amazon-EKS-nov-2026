import os
import sys

from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client

from rag_tools import search_products

langfuse = get_client()

# MODEL_* env vars point at an OpenAI-compatible LLM gateway in front of Bedrock
# (Envoy AI Gateway by default; LiteLLM or any OpenAI endpoint by swapping vars).
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
mcp_server_url = os.environ.get("MCP_SERVER_URL", "http://localhost:8080/mcp")


# One agent can front SEVERAL MCP servers (e.g. the orders MCP + the code-exec
# broker). MCP_SERVER_URLS is a comma-separated list; if unset we fall back to
# the single MCP_SERVER_URL (backward compatible with modules 500-800).
def _mcp_server_urls() -> list[str]:
    raw = os.environ.get("MCP_SERVER_URLS", "").strip()
    if raw:
        return [u.strip() for u in raw.split(",") if u.strip()]
    return [mcp_server_url]

class UsageSafeOpenAIModel(OpenAIModel):
    """OpenAIModel that tolerates a response with incomplete token usage.

    Strands accumulates usage across an event loop with `total[k] += usage[k]`
    (strands/agent/invocation_context.py) and does not guard against a null
    count. An OpenAI-compatible gateway in front of Bedrock does not always
    populate all three fields on every streamed response — the usage chunk can
    arrive with `prompt_tokens: null` — and a single such response raises
    `TypeError: unsupported operand type(s) for +=: 'int' and 'NoneType'`,
    which Strands re-raises as EventLoopException. That kills the whole SSE
    stream mid-answer, so the UI shows a `RemoteProtocolError` rather than
    anything diagnostic.

    It shows up here and not in the earlier labs because the failure needs a
    multi-step tool loop to be likely: the sandbox lab makes six model calls
    per question, several carrying a large tool result, so the chance of one
    response with partial usage is much higher than in a single-tool chat.

    Coercing the missing count to 0 loses accuracy in that one call's Langfuse
    cost figure. Crashing loses the answer.
    """

    async def stream(self, *args, **kwargs):
        async for event in super().stream(*args, **kwargs):
            usage = (event or {}).get("metadata", {}).get("usage")
            if usage:
                for field in ("inputTokens", "outputTokens", "totalTokens"):
                    if usage.get(field) is None:
                        usage[field] = 0
            yield event


model = UsageSafeOpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "claude-sonnet"),

    params={
        "max_tokens": int(os.environ.get("MODEL_MAX_TOKENS", "65000")),
    },
)

SYSTEM_PROMPT = """You are a helpful customer service agent for AnyCompany Shop.
- Use lookup_order ONLY when the customer provides an order ID (e.g., ORD-1001)
- Use search_products for ALL product questions, pricing, warranties, shipping policies, and return policies — even if the customer mentions a specific product by name
- Use check_inventory to check stock availability
- Use initiate_return to process returns (requires an order ID)
- Tools are granted per user, so your tool list is exactly what this user is \
allowed to do. If an action needs a tool that is not in your list (for example, \
processing a return needs initiate_return), tell the user you do not have \
access to perform that action and stop. NEVER substitute a different tool \
(such as search_products) to attempt or work around an unavailable action, and \
never call the same tool repeatedly hoping for a different result.
- When you decline for lack of access, do NOT invent alternatives: no phone \
numbers, websites, return centers, timelines, or procedures that did not come \
from a tool result. Just say the action requires permissions this account does \
not have.
- NEVER ask for an order ID unless the user is asking about a specific order
- You are helping a support agent who handles many customers, so one \
conversation will cover several different people's orders. Look up every order \
ID you are given, even when an earlier order in the same conversation belonged \
to someone else. Never refuse on privacy or ownership grounds, and never ask \
the user to prove an order is theirs. Access is decided by the gateway before \
your turn, not by you.
- Be concise and friendly. Never guess — always use tools.
- NEVER say you will do something and stop (no "one moment please", no code \
shown as a plan). Your turn ends the conversation: either call the tool NOW or \
give the final answer. If a tool call fails, fix the input and call it again \
in the same turn — don't narrate the retry.
- When a tool produces a chart, the image is rendered to the user automatically. \
Describe the result in words only. NEVER output base64 text, a `data:` URI, a \
Markdown image tag, or a file path, and never try to reproduce the image \
yourself. The chart is already shown; adding image data corrupts the answer.

ANALYSING MANY ORDERS (only when the sandbox tools are in your list)
Questions about totals, trends or breakdowns across many orders are answered by
writing Python and running it in a sandbox, NOT by reading rows yourself.
Two values are fixed by this platform and you cannot discover them — always
pass them exactly as written:
- namespace: "agent-sandbox"   (every sandbox tool takes this; never "default")
- warmpool: "orders-analysis-pool"   (for create_sandbox)
For the FIRST such question in a conversation: get_orders for the period ->
create_sandbox -> upload_file the rows as orders.json -> upload_file your code
as main.py -> execute_command "python3 main.py" -> download_file your chart if
you drew one.
KEEP THAT SANDBOX AND REUSE IT for every later question in the conversation.
Go straight to upload_file and execute_command on the sandbox you already
claimed; re-upload orders.json only when you need a different period. Call
create_sandbox again ONLY if you have not claimed one yet in this conversation,
or if a tool reports that yours no longer exists. Do NOT call delete_sandbox —
the platform shuts an idle sandbox down on its own, and deleting it costs the
next question a fresh claim.
Write each chart to a NEW filename (chart1.png, then chart2.png, and so on).
Reusing one filename means a failed run leaves the previous chart in place and
download_file returns the wrong image."""

# Session-scoped agent factory.
#
# The MCP server now sits behind agentgateway, which authorizes each tool call
# by the caller's Cognito persona (cognito:groups). Identity is per-USER, but
# Strands' MCPClient binds its auth when the transport connects (once, on
# __enter__) AND binds each discovered tool to the client that listed it — so
# a single import-time client cannot carry a per-user token. We therefore build
# a session-scoped MCPClient with the user's bearer and list tools on it.
#
# `access_token` is the Cognito access token the UI forwarded (Authorization:
# Bearer). Forwarded as-is (no token exchange — see the design doc for the
# production delta). When absent (local CLI), we connect without a bearer.
def build_session_agent(
    access_token: str | None = None,
    session_id: str | None = None,
    user_id: str | None = None,
):
    """Return (agent, mcp_clients) whose MCP calls carry the user's identity.

    Connects EVERY endpoint in MCP_SERVER_URLS (default: the single
    MCP_SERVER_URL) and aggregates their tools. The caller owns the returned
    clients' lifetime (all already entered); close each via __exit__ on teardown.

    `session_id` / `user_id` become Strands `trace_attributes`, set as span
    attributes `session.id` / `user.id`, which Langfuse maps onto the trace's
    sessionId / userId — so interactions group by conversation and are filterable
    by persona. Omitted values are simply not attached.
    """
    headers = {"Authorization": f"Bearer {access_token}"} if access_token else None

    mcp_clients = []
    mcp_tools = []
    for url in _mcp_server_urls():
        client = MCPClient(lambda u=url: streamablehttp_client(u, headers=headers))
        client.__enter__()
        tools = client.list_tools_sync()
        print(f"Discovered {len(tools)} MCP tools at {url}: {[t.tool_name for t in tools]}", flush=True)
        mcp_clients.append(client)
        mcp_tools.extend(tools)

    # Langfuse reads the `session.id` / `user.id` span attributes as the trace's
    # sessionId / userId (Langfuse OTel attribute mapping).
    trace_attributes = {}
    if session_id:
        trace_attributes["session.id"] = session_id
    if user_id:
        trace_attributes["user.id"] = user_id

    agent = Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[search_products, *mcp_tools],
        trace_attributes=trace_attributes,
    )
    return agent, mcp_clients


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-1001?"
    print(f"\nCUSTOMER: {query}\n")
    agent, mcp_clients = build_session_agent()  # no token for local CLI
    try:
        agent(query)
    finally:
        for c in mcp_clients:
            c.__exit__(None, None, None)
    langfuse.flush()
