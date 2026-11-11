import os

from fastembed import TextEmbedding
from langfuse import observe
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from pymilvus import MilvusClient
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

MILVUS_URI = os.environ.get("MILVUS_URI", "http://milvus.milvus.svc.cluster.local:19530")
# MODEL_* env vars point at an OpenAI-compatible LLM gateway in front of Bedrock
# (Envoy AI Gateway by default; LiteLLM or any OpenAI endpoint by swapping vars).
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")
# Must match the path the Dockerfile pre-populates during build.
MODEL_CACHE = "/app/.fastembed_cache"

_embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=MODEL_CACHE,
)
_milvus = MilvusClient(uri=MILVUS_URI)


@tool
@observe(name="milvus.search_products")
def search_products(query: str, limit: int = 5) -> list:
    """Search product catalog and FAQs."""
    embeddings = [v.tolist() for v in _embedder.embed([query])]
    results = _milvus.search(
        "product_catalog",
        data=embeddings,
        limit=limit,
        output_fields=["name", "category", "price", "description"],
    )
    return [
        {
            "name": h["entity"]["name"],
            "price": f"${h['entity']['price']:.2f}" if h["entity"]["price"] > 0 else "N/A",
            "description": h["entity"]["description"],
        }
        for h in results[0]
    ]


model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "claude-sonnet"),
    params={"max_tokens": 65000},
)


class ProductAgentExecutor(AgentExecutor):
    def __init__(self):
        self.agent = Agent(
            model=model,
            system_prompt=(
                "You help customers find products. Use search_products to find items. "
                "Be concise with recommendations."
            ),
            tools=[search_products],
        )

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()
        reply = str(self.agent(query))
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        pass


agent_card = AgentCard(
    name="Product Agent",
    description="Searches product catalog and answers product questions",
    url="http://product-agent.default.svc.cluster.local:8082",
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="products",
            name="Product Search",
            description="Find products, compare options, check pricing and policies",
            tags=["products", "search", "pricing"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=ProductAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=8082)
