import asyncio
import contextvars
import os
import sys
import uuid

import httpx
from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from a2a.client import A2AClient
from a2a.types import (
    Message,
    MessageSendParams,
    Role,
    SendMessageRequest,
    TextPart,
)

langfuse = get_client()

# MODEL_* env vars point at an OpenAI-compatible LLM gateway in front of Bedrock
# (Envoy AI Gateway by default; LiteLLM or any OpenAI endpoint by swapping vars).
# NOTE: ORDER_AGENT_URL / PRODUCT_AGENT_URL below are the agent-to-agent (A2A)
# endpoints — unrelated to the model gateway; leave them as-is.
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
order_agent_url = os.environ.get(
    "ORDER_AGENT_URL", "http://order-agent.default.svc.cluster.local:8081"
)
product_agent_url = os.environ.get(
    "PRODUCT_AGENT_URL", "http://product-agent.default.svc.cluster.local:8082"
)

# Per-request Cognito bearer, set by server.py before invoking the agent and
# read inside the A2A tool calls. A ContextVar (not a function arg) because the
# @tool functions are invoked BY the Strands agent, not by us — Strands
# propagates context into tool execution, so the token rides along. Forwarding
# it on each A2A call lets agentgateway authenticate the persona on the A2A hop
# (800-multi-agent-authz) and lets the specialist propagate it on to MCP.
_access_token: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "access_token", default=None
)


def _extract_text(response) -> str:
    """Pull the textual reply out of a SendMessageResponse.

    The result can be either a Message (direct reply) or a Task (which carries
    artifacts). Both expose `parts` lists with TextPart entries.
    """
    result = getattr(response.root, "result", None) or response.root
    parts = list(getattr(result, "parts", None) or [])
    for artifact in getattr(result, "artifacts", None) or []:
        parts.extend(artifact.parts or [])
    texts = [getattr(p.root, "text", None) for p in parts]
    texts = [t for t in texts if t]
    return "\n".join(texts) or str(result)


async def _ask(base_url: str, query: str) -> str:
    # A2AClient wraps httpx.AsyncClient and speaks JSON-RPC 2.0.
    async with httpx.AsyncClient(timeout=120) as http:
        client = A2AClient(httpx_client=http, url=base_url)
        request = SendMessageRequest(
            id=str(uuid.uuid4()),
            params=MessageSendParams(
                message=Message(
                    message_id=str(uuid.uuid4()),
                    role=Role.user,
                    parts=[TextPart(text=query)],
                )
            ),
        )
        # Forward the user's Cognito bearer per-call so agentgateway can
        # authenticate the persona on the A2A hop. send_message takes per-call
        # http_kwargs → httpx headers (no client-lifetime auth binding).
        token = _access_token.get()
        http_kwargs = (
            {"headers": {"Authorization": f"Bearer {token}"}} if token else None
        )
        response = await client.send_message(request, http_kwargs=http_kwargs)
        return _extract_text(response)


@tool
def ask_order_agent(query: str) -> str:
    """Route order-related queries (status, tracking, returns) to the Order Agent."""
    return asyncio.run(_ask(order_agent_url, query))


@tool
def ask_product_agent(query: str) -> str:
    """Route product questions (search, pricing, policies) to the Product Agent."""
    return asyncio.run(_ask(product_agent_url, query))


model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "claude-sonnet"),
    params={"max_tokens": 65000},
)

SYSTEM_PROMPT = """You are a routing agent. You NEVER answer questions directly.
You MUST always use one of your tools to handle every customer request.

Routing rules:
- Any question mentioning order IDs, order status, tracking, or returns → ask_order_agent
- Product questions, pricing, warranties, shipping policies, or return policies → ask_product_agent
- If a request needs info from both specialists, call them in sequence

IMPORTANT:
- Do NOT attempt to answer from your own knowledge. Always delegate to a specialist.
- Specialists have no memory — they only see what you send them. When the customer's message is ambiguous or references earlier context, enrich the query with the relevant details (order IDs, product names, etc.) from the conversation history before routing."""


# Session-scoped orchestrator factory.
#
# `session_id` / `user_id` become Strands `trace_attributes`, set as span
# attributes `session.id` / `user.id`, which Langfuse maps onto the trace's
# sessionId / userId — so interactions group by conversation and are filterable
# by persona (sales-analyst vs support-associate). The orchestrator's FastAPI
# span is the trace root and the specialists' spans nest under it (shared
# traceparent), so labelling the orchestrator labels the whole multi-agent
# trace. Strands binds trace_attributes at construction, so this is a factory
# rather than a shared module-level agent: server.py builds one per session.
def build_session_agent(
    session_id: str | None = None,
    user_id: str | None = None,
):
    trace_attributes = {}
    if session_id:
        trace_attributes["session.id"] = session_id
    if user_id:
        trace_attributes["user.id"] = user_id

    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[ask_order_agent, ask_product_agent],
        trace_attributes=trace_attributes,
    )


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-1001?"
    print(f"\nCUSTOMER: {query}\n")
    build_session_agent()(query)  # no token for local CLI
    langfuse.flush()
