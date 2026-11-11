"""One-time seed of the product catalog into Milvus.

`search_products` (rag_tools.py) does a vector search over the `product_catalog`
collection; that collection has to be created and populated once per cluster.
The already-deployed customer-agent pod carries everything the seed needs
(fastembed + pymilvus + the pre-baked model cache + MILVUS_URI), so run this
script INSIDE that pod by piping it over stdin — no extra image or rebuild:

    kubectl exec -i deploy/customer-agent -n default -- python - \\
      < modules/500-agent-tools-mcp/customer-agent/seed_products.py

Idempotent: re-running drops and recreates the collection, so editing the
product list below and re-running reseeds cleanly.
"""

import os

from fastembed import TextEmbedding
from pymilvus import MilvusClient

MILVUS_URI = os.environ.get("MILVUS_URI", "http://localhost:19530")
COLLECTION = "product_catalog"
# Must match the path the Dockerfile pre-populates during build.
MODEL_CACHE = "/app/.fastembed_cache"

embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=MODEL_CACHE,
)

PRODUCTS = [
    {"id": 1, "name": "Laptop Pro 15", "category": "Electronics", "price": 1299.99,
     "description": "15-inch laptop with 16GB RAM, 512GB SSD, and a 10-hour battery life."},
    {"id": 2, "name": "Wireless Mouse", "category": "Accessories", "price": 29.99,
     "description": "Ergonomic wireless mouse with USB-C receiver. Silent clicks, 6-month battery life."},
    {"id": 3, "name": "USB-C Hub", "category": "Accessories", "price": 49.99,
     "description": "7-in-1 USB-C hub with HDMI, USB-A, SD card reader, and 100W power delivery."},
    {"id": 4, "name": "Noise Cancelling Headphones", "category": "Audio", "price": 249.99,
     "description": "Over-ear wireless headphones with active noise cancellation. 30-hour battery."},
    {"id": 5, "name": "Mechanical Keyboard", "category": "Accessories", "price": 89.99,
     "description": "Compact 75% mechanical keyboard with hot-swappable switches and RGB backlighting."},
    {"id": 6, "name": "4K Monitor 27-inch", "category": "Electronics", "price": 399.99,
     "description": "27-inch 4K IPS monitor with USB-C input, 99% sRGB coverage."},
    {"id": 7, "name": "Webcam HD Pro", "category": "Accessories", "price": 79.99,
     "description": "1080p webcam with auto-focus, built-in microphone, and privacy shutter."},
    {"id": 8, "name": "Portable Charger 20000mAh", "category": "Accessories", "price": 39.99,
     "description": "Slim portable charger with 20000mAh capacity. USB-C and USB-A outputs."},
    {"id": 9, "name": "Wireless Earbuds", "category": "Audio", "price": 59.99,
     "description": "True wireless earbuds with 8-hour battery, IPX5 water resistance."},
    {"id": 10, "name": "Laptop Stand", "category": "Accessories", "price": 34.99,
     "description": "Adjustable aluminum laptop stand. Raises screen to eye level."},
    {"id": 101, "name": "Return Policy", "category": "FAQ", "price": 0,
     "description": "30-day return policy. Items must be in original packaging. Refunds in 5-7 business days."},
    {"id": 102, "name": "Shipping Info", "category": "FAQ", "price": 0,
     "description": "Free standard shipping over $50 (3-5 days). Express $9.99 (1-2 days)."},
    {"id": 103, "name": "Warranty", "category": "FAQ", "price": 0,
     "description": "Electronics: 1-year warranty. Accessories: 6-month warranty. Extended warranty available."},
]

client = MilvusClient(uri=MILVUS_URI)
if client.has_collection(COLLECTION):
    client.drop_collection(COLLECTION)
# consistency_level="Strong" is load-bearing, not a tuning knob. Milvus inserts
# land in a growing segment and are NOT searchable until the reader catches up;
# under the MilvusClient default ("Bounded", a few seconds of allowed staleness)
# the test search at the bottom of this script runs before the rows are visible
# and prints nothing, which reads as "the seed failed". "Strong" makes each
# search wait for everything inserted so far, so the seed can verify itself and
# search_products works the instant this script finishes.
client.create_collection(
    collection_name=COLLECTION,
    dimension=384,
    consistency_level="Strong",
)

vectors = [v.tolist() for v in embedder.embed([p["description"] for p in PRODUCTS])]
data = [{**p, "vector": vec} for p, vec in zip(PRODUCTS, vectors)]
client.insert(collection_name=COLLECTION, data=data)
print(f"Inserted {len(data)} items into '{COLLECTION}'")

query_vec = [v.tolist() for v in embedder.embed(["wireless headphones"])]
results = client.search(
    COLLECTION,
    data=query_vec,
    limit=3,
    output_fields=["name", "price"],
)
print("\nTest search 'wireless headphones':")
for hit in results[0]:
    print(f"  {hit['entity']['name']} (${hit['entity']['price']})")
