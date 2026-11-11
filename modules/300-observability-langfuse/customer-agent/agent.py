import os
import sys

from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order

# Langfuse config (LANGFUSE_PUBLIC_KEY, LANGFUSE_SECRET_KEY, LANGFUSE_BASE_URL)
# is supplied by the `agent-config` ConfigMap when running on EKS.
langfuse = get_client()
if langfuse.auth_check():
    print("Langfuse connected successfully")
else:
    print("WARNING: Langfuse authentication failed — traces will not be captured")

# MODEL_* env vars point at an OpenAI-compatible LLM gateway in front of Bedrock
# (Envoy AI Gateway by default; LiteLLM or any OpenAI endpoint by swapping vars).
model_base_url = os.environ.get("MODEL_BASE_URL", "http://localhost:4000/v1")

model = OpenAIModel(
    client_args={
        "base_url": model_base_url,
        "api_key": os.environ.get("MODEL_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "claude-sonnet"),
    params={"max_tokens": 65000},
)

SYSTEM_PROMPT = """You are a friendly and helpful customer service agent for AnyCompany Shop, an online retail store.

Your job is to assist customers with:
1. Order inquiries — use the lookup_order tool to check order status, shipping updates, delivery estimates
2. Product questions — help customers find the right product, compare options, check availability
3. Returns and refunds — guide customers through the return process, explain policies
4. General support — answer FAQs about shipping, payment methods, and store policies

Guidelines:
- Be warm, professional, and concise
- If you don't have enough information to help, ask clarifying questions
- Always confirm the customer's issue before suggesting a solution
- For order-related queries, ask for the order ID if not provided, then use the lookup_order tool
- Present order information in a clear, readable format
- Never make up order details — always use the lookup_order tool
- You are helping a support agent who handles many customers, so one
  conversation will cover several different people's orders. Look up every order
  ID you are given, even when an earlier order in the same conversation belonged
  to someone else. Never refuse on privacy or ownership grounds, and never ask
  the user to prove an order is theirs. Whether this user may see an order is
  decided before your turn, not by you.
"""

# Session-scoped agent factory.
#
# `session_id` / `user_id` become Strands `trace_attributes`, set as span
# attributes `session.id` / `user.id`, which Langfuse maps onto the trace's
# sessionId / userId — so interactions group by conversation and are filterable
# by persona (sales-analyst vs support-associate). Omitted values are simply not
# attached. Strands binds trace_attributes at construction, so this is a factory
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
        tools=[lookup_order],
        trace_attributes=trace_attributes,
    )


if __name__ == "__main__":
    query = (
        " ".join(sys.argv[1:]) if len(sys.argv) > 1
        else "Hi, I ordered a laptop last week and it still hasn't arrived. My order ID is ORD-1001. Can you help?"
    )

    print(f"\n{'=' * 60}\nCUSTOMER: {query}\n{'=' * 60}\n")
    build_session_agent()(query)  # no token for local CLI
    langfuse.flush()
    print(f"\n{'=' * 60}\nAgent response complete. Check Langfuse for the trace.")
