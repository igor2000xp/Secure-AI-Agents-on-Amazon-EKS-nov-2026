import boto3, json, os

from boto3.dynamodb.types import TypeDeserializer
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

from query import build_query_kwargs, InvalidQueryParam

# DNS rebinding protection blocks in-cluster DNS like `mcp-server.default.svc.
# cluster.local`. That protection matters for browsers hitting localhost; this
# is a ClusterIP Service only other pods talk to, so we turn it off.
mcp = FastMCP(
    "AnyCompany Tools",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

_REGION = os.environ.get("AWS_REGION")
_TABLE_NAME = os.environ["ORDERS_TABLE"]
_TABLE = boto3.resource("dynamodb", region_name=_REGION).Table(_TABLE_NAME)
# get_orders needs a Query against the period GSI, which the resource-level
# Table API expresses awkwardly; the low-level client takes the kwargs query.py
# builds directly.
_CLIENT = boto3.client("dynamodb", region_name=_REGION)
_DESER = TypeDeserializer()

# Cap on rows handed back to the agent. A fiscal quarter is a few hundred orders
# in the sample data; this is a guard against a future dataset making one tool
# call blow the model's context window, not a security control.
MAX_ROWS = int(os.environ.get("GET_ORDERS_MAX_ROWS", "2000"))

INVENTORY = {
    "Laptop Pro 15": 23, "Wireless Mouse": 156, "USB-C Hub": 89,
    "Noise Cancelling Headphones": 45, "Mechanical Keyboard": 67,
    "4K Monitor 27-inch": 12, "Webcam HD Pro": 98,
    "Portable Charger 20000mAh": 203, "Wireless Earbuds": 134, "Laptop Stand": 76,
}


@mcp.tool()
def lookup_order(order_id: str) -> dict:
    """Look up order status, tracking, and details by order ID."""
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
    item = resp.get("Item")
    if not item:
        return {"error": f"Order {order_id} not found."}
    items = json.loads(item["items"])
    order = {
        "customer": item["customer"],
        "items": items,
        "status": item["status"],
        "tracking": item.get("tracking"),
        "estimated_delivery": item["estimated_delivery"],
    }
    total = float(sum(i["price"] * i["qty"] for i in items))
    return {"order_id": order_id.upper(), **order, "total": f"${total:.2f}"}


@mcp.tool()
def check_inventory(product_name: str) -> dict:
    """Check stock availability for a product."""
    for name, qty in INVENTORY.items():
        if product_name.lower() in name.lower():
            return {"product": name, "in_stock": qty > 0, "quantity": qty}
    return {"error": f"Product '{product_name}' not found in inventory."}


@mcp.tool()
def initiate_return(order_id: str, reason: str) -> dict:
    """Initiate a return for an order. Returns a return authorization number."""
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
    item = resp.get("Item")
    if not item:
        return {"error": f"Order {order_id} not found."}
    if item["status"] == "processing":
        return {"error": "Cannot return an order that hasn't shipped yet. Please cancel instead."}
    return {
        "return_id": f"RET-{order_id.upper().replace('ORD-', '')}",
        "order_id": order_id.upper(),
        "status": "approved",
        "reason": reason,
        "instructions": "Ship the item to: AnyCompany Returns, 100 Warehouse Blvd, Seattle, WA 98101",
    }


@mcp.tool()
def get_orders(
    period: str,
    region: str | None = None,
    status: str | None = None,
    payment_method: str | None = None,
    channel: str | None = None,
) -> dict:
    """Fetch one fiscal quarter of orders, optionally filtered, for analysis.

    Use this when a question spans MANY orders (totals, trends, breakdowns by
    region/product/state) rather than one order — `lookup_order` is the tool for
    a single order ID. Pair it with the sandbox tools: fetch the slice here,
    upload it into a sandbox, and analyse it there with pandas.

    Data is fetched a whole quarter at a time. For a single month, pass the
    quarter that contains it and filter on `order_date` in your analysis code.

    Each row has: order_id, customer, status (shipped|delivered|processing|
    cancelled|returned), tracking (absent for processing/cancelled),
    estimated_delivery, shipping_address, items (list of {name, qty, price}),
    total (float, the order's full value), order_date (ISO date), period,
    region (West|South|Central|East), state (2-letter),
    payment_method (credit_card|debit_card|gift_card), channel (web|mobile).

    Args:
      period: REQUIRED fiscal quarter, e.g. "2026-Q1".
      region: optional filter (West|South|Central|East).
      status: optional filter (shipped|delivered|processing|cancelled|returned).
      payment_method: optional filter (credit_card|debit_card|gift_card).
      channel: optional filter (web|mobile).
    """
    try:
        kwargs = build_query_kwargs(
            _TABLE_NAME, period=period, region=region, status=status,
            payment_method=payment_method, channel=channel,
        )
    except InvalidQueryParam as e:
        return {"error": f"invalid query parameter: {e}"}

    rows: list[dict] = []
    truncated = False
    while True:
        resp = _CLIENT.query(**kwargs)
        for item in resp.get("Items", []):
            row = {k: _DESER.deserialize(v) for k, v in item.items()}
            # `items` is stored as a JSON string and `total` as a String, so
            # parse both — otherwise analysis code concatenates strings instead
            # of summing numbers.
            if isinstance(row.get("items"), str):
                row["items"] = json.loads(row["items"])
            if isinstance(row.get("total"), str):
                row["total"] = float(row["total"])
            rows.append(row)
            if len(rows) >= MAX_ROWS:
                truncated = True
                break
        if truncated:
            break
        lek = resp.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek

    out = {"period": period, "row_count": len(rows), "orders": rows}
    if truncated:
        out["truncated"] = True
        out["note"] = f"capped at {MAX_ROWS} rows; narrow the query with a filter"
    return out


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.streamable_http_app(), host="0.0.0.0", port=8080)
