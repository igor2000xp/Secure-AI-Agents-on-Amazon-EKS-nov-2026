import os

from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

# MODEL_* env vars point at an OpenAI-compatible LLM gateway in front of Bedrock
# (Envoy AI Gateway by default; LiteLLM or any OpenAI endpoint by swapping vars).
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
mcp_server_url = os.environ.get(
    "MCP_SERVER_URL", "http://mcp-server.default.svc.cluster.local:8080/mcp"
)

model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "claude-sonnet"),
    params={"max_tokens": 65000},
)

SYSTEM_PROMPT = (
    "You handle order inquiries. Use lookup_order to check status and "
    "initiate_return for returns. Be concise."
)


def _incoming_bearer(context: RequestContext) -> str | None:
    """Read the Authorization bearer the orchestrator forwarded on the A2A call.

    The a2a default context builder populates
    ServerCallContext.state['headers'] with the incoming request headers, so we
    read the token there (no custom context builder needed). Forwarding it to
    the MCP client lets agentgateway enforce per-tool persona authz downstream.
    """
    call_ctx = getattr(context, "call_context", None)
    headers = (call_ctx.state.get("headers") if call_ctx else None) or {}
    auth = headers.get("authorization") or headers.get("Authorization")
    if auth and auth.lower().startswith("bearer "):
        return auth[7:]
    return None


class OrderAgentExecutor(AgentExecutor):
    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()

        # Build a request-scoped MCP client carrying the forwarded persona token.
        # Strands' MCPClient binds auth at connect and binds tools to the listing
        # client, so a per-request client is required to carry per-user identity
        # (same rationale as the 500 customer-agent). agentgateway then authorizes
        # each tool call by the persona's cognito:groups claim.
        token = _incoming_bearer(context)
        headers = {"Authorization": f"Bearer {token}"} if token else None
        mcp_client = MCPClient(lambda: streamablehttp_client(mcp_server_url, headers=headers))
        mcp_client.__enter__()
        try:
            agent = Agent(
                model=model,
                system_prompt=SYSTEM_PROMPT,
                tools=mcp_client.list_tools_sync(),
            )
            reply = str(agent(query))
        finally:
            mcp_client.__exit__(None, None, None)
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        # Strands Agent has no in-flight cancellation hook, so this is a no-op.
        pass


agent_card = AgentCard(
    name="Order Agent",
    description="Handles order status lookups and return processing",
    url="http://order-agent.default.svc.cluster.local:8081",
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="orders",
            name="Order Management",
            description="Look up orders, track shipments, process returns",
            tags=["orders", "returns", "tracking"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=OrderAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=8081)
