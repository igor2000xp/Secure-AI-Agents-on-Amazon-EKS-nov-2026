"""Build a scoped DynamoDB Query from LLM-supplied, validated parameters.

Backs the `get_orders` tool in server.py. The model chooses WHAT to fetch
(period + optional filters); this module turns those VALUES into a
parameterized Query on the orders `period-index` GSI. The model never supplies
raw expressions, table names or index names, so it cannot widen or retarget the
query — it picks values from allow-lists and gets back one quarter's slice.
"""

import re

GSI_NAME = "period-index"

_PERIOD_RE = re.compile(r"^\d{4}-Q[1-4]$")

# Allow-lists mirror terraform/data/generate_orders.py.
_VALID_STATUS = {"shipped", "delivered", "processing", "cancelled", "returned"}
_VALID_PAYMENT = {"credit_card", "debit_card", "gift_card"}
_VALID_REGION = {"West", "South", "Central", "East"}
_VALID_CHANNEL = {"web", "mobile"}


class InvalidQueryParam(ValueError):
    """Raised when an LLM-supplied query parameter fails validation."""


def build_query_kwargs(
    table: str,
    *,
    period: str,
    region: str | None = None,
    status: str | None = None,
    payment_method: str | None = None,
    channel: str | None = None,
) -> dict:
    """Return boto3 client `query()` kwargs for a period slice + optional filters.

    Raises InvalidQueryParam if any value is malformed / not in an allow-list.
    """
    if not _PERIOD_RE.match(period or ""):
        raise InvalidQueryParam(f"period must look like '2026-Q1', got {period!r}")

    names = {"#p": "period"}
    values = {":period": {"S": period}}
    kwargs = {
        "TableName": table,
        "IndexName": GSI_NAME,
        "KeyConditionExpression": "#p = :period",
    }

    # (field, value, allow_list) — each optional filter is validated then added.
    optional = [
        ("region", region, _VALID_REGION),
        ("status", status, _VALID_STATUS),
        ("payment_method", payment_method, _VALID_PAYMENT),
        ("channel", channel, _VALID_CHANNEL),
    ]
    filters = []
    for field, value, allowed in optional:
        if value is None:
            continue
        if value not in allowed:
            raise InvalidQueryParam(f"{field} must be one of {sorted(allowed)}, got {value!r}")
        names[f"#{field}"] = field
        values[f":{field}"] = {"S": value}
        filters.append(f"#{field} = :{field}")

    kwargs["ExpressionAttributeNames"] = names
    kwargs["ExpressionAttributeValues"] = values
    if filters:
        kwargs["FilterExpression"] = " AND ".join(filters)
    return kwargs
