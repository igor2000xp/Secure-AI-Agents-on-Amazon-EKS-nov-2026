import os
import sys

from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order

# MODEL_BASE_URL / MODEL_ID / MODEL_API_KEY come from the `agent-config`
# ConfigMap on EKS. They point at an OpenAI-compatible LLM gateway in front of
# Amazon Bedrock — the Envoy AI Gateway by default, but any OpenAI-compatible
# endpoint (e.g. LiteLLM) works by changing these env vars. The integrated
# track uses the same client with a different `MODEL_ID`.
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

# A factory, not a module-level `agent`, because a Strands Agent KEEPS THE
# CONVERSATION on itself. One shared agent means one shared conversation: every
# chat in the UI, and every signed-in user, appends to the same history. The
# visible symptom is the model answering a second customer's question in the
# first customer's context, and sometimes refusing it outright ("I can't share
# details about an order that isn't yours") because the earlier turns say the
# caller is someone else.
#
# server.py therefore holds one agent per chat session. For the CLI below, one
# process is one conversation, so it just builds its own.
def build_agent() -> Agent:
    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[lookup_order],
    )


if __name__ == "__main__":
    agent = build_agent()

    if len(sys.argv) > 1:
        query = " ".join(sys.argv[1:])
    else:
        query = "Hi, I ordered a laptop last week and it still hasn't arrived. My order ID is ORD-1001. Can you help?"

    print(f"\n{'=' * 60}")
    print(f"CUSTOMER: {query}")
    print(f"{'=' * 60}\n")

    agent(query)

    print(f"\n{'=' * 60}")
    print("Agent response complete.")
