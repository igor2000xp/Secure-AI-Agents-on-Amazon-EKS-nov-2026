import json
import os

import boto3
from strands.tools import tool

_TABLE = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION")).Table(os.environ["ORDERS_TABLE"])


@tool
def lookup_order(order_id: str) -> dict:
    """Look up an order by its order ID and return the order details.

    Args:
        order_id: The order ID to look up (e.g., ORD-1001)

    Returns:
        A dictionary containing order details including items, status, tracking number,
        and estimated delivery date. Returns an error message if the order is not found.
    """
    resp = _TABLE.get_item(Key={"order_id": order_id.upper()})
    item = resp.get("Item")
    if not item:
        return {"error": f"Order {order_id} not found. Please verify the order ID and try again."}

    items = json.loads(item["items"])
    total = float(sum(i["price"] * i["qty"] for i in items))
    return {
        "order_id": order_id.upper(),
        "customer": item["customer"],
        "items": items,
        "total": f"${total:.2f}",
        "status": item["status"],
        "tracking_number": item.get("tracking"),
        "estimated_delivery": item["estimated_delivery"],
        "shipping_address": item["shipping_address"],
    }
