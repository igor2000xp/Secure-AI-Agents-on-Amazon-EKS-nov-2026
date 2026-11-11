import pytest
from query import build_query_kwargs, InvalidQueryParam

TABLE = "wsx-orders"


def test_period_only_queries_the_gsi():
    kw = build_query_kwargs(TABLE, period="2026-Q1")
    assert kw["TableName"] == TABLE
    assert kw["IndexName"] == "period-index"
    assert kw["KeyConditionExpression"] == "#p = :period"
    assert kw["ExpressionAttributeNames"] == {"#p": "period"}
    assert kw["ExpressionAttributeValues"] == {":period": {"S": "2026-Q1"}}
    assert "FilterExpression" not in kw


def test_optional_filters_become_a_filter_expression():
    kw = build_query_kwargs(TABLE, period="2026-Q1", region="West", status="delivered")
    assert kw["FilterExpression"] == "#region = :region AND #status = :status"
    assert kw["ExpressionAttributeNames"]["#region"] == "region"
    assert kw["ExpressionAttributeNames"]["#status"] == "status"
    assert kw["ExpressionAttributeValues"][":region"] == {"S": "West"}
    assert kw["ExpressionAttributeValues"][":status"] == {"S": "delivered"}


def test_bad_period_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query_kwargs(TABLE, period="Q1-2026")


def test_unknown_payment_method_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query_kwargs(TABLE, period="2026-Q1", payment_method="crypto")


def test_unknown_status_is_rejected():
    with pytest.raises(InvalidQueryParam):
        build_query_kwargs(TABLE, period="2026-Q1", status="teleported")
