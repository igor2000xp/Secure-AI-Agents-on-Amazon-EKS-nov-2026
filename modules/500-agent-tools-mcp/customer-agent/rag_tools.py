import os

from fastembed import TextEmbedding
from langfuse import observe
from pymilvus import MilvusClient
from strands.tools import tool

MILVUS_URI = os.environ.get("MILVUS_URI", "http://localhost:19530")
COLLECTION = "product_catalog"
# Must match the path the Dockerfile pre-populates during build.
MODEL_CACHE = "/app/.fastembed_cache"

# fastembed ships the same all-MiniLM-L6-v2 weights pre-converted to ONNX, so
# vectors are interchangeable with anything sentence-transformers produced —
# but runtime is onnxruntime (~20 MB) instead of torch (~170 MB).
_embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=MODEL_CACHE,
)
_client = MilvusClient(uri=MILVUS_URI)


@tool
@observe(name="milvus.search_products")
def search_products(query: str, limit: int = 5) -> list:
    """Search the AnyCompany Shop product catalog and FAQs."""
    try:
        embeddings = [v.tolist() for v in _embedder.embed([query])]
        results = _client.search(
            COLLECTION,
            data=embeddings,
            limit=limit,
            output_fields=["name", "category", "price", "description"],
        )
    except Exception as exc:
        # Never raise from a tool: the system prompt tells the model to retry a
        # failed tool call, so a raised error here (collection not yet seeded,
        # Milvus briefly unreachable) makes it retry the SAME call indefinitely.
        # Return a terminal, human-readable result so the turn ends cleanly.
        print(f"[search_products] catalog search failed: {exc!r}", flush=True)
        return [{"message": "The product catalog is temporarily unavailable. Please try again in a moment."}]
    items = []
    for hit in results[0]:
        e = hit["entity"]
        item = {"name": e["name"], "category": e["category"], "description": e["description"]}
        if e["price"] > 0:
            item["price"] = f"${e['price']:.2f}"
        items.append(item)
    return items or [{"message": "No matching products found."}]
