#!/usr/bin/env bash
# Enable Bedrock model access for the Anthropic Claude models the coding agent
# uses. Anthropic models on Bedrock are delivered through AWS Marketplace, so
# the account must hold a foundation-model agreement (subscription) before they
# can be invoked — WITHOUT it the /anthropic gateway route returns 403
# AccessDenied ("aws-marketplace:ViewSubscriptions, Subscribe"), even though
# bedrock:InvokeModel is granted. First-party models (Amazon Nova) need none of
# this, so they work regardless.
#
# The models are invoked through CROSS-REGION inference profiles (us.anthropic.*),
# which route to us-east-1 / us-east-2 / us-west-2, so we subscribe in each. This
# is best-effort and IDEMPOTENT: "already exists" is success, and a region the
# account cannot use (e.g. an SCP-restricted region) is logged and skipped rather
# than failing the apply. Requires the caller to hold aws-marketplace:Subscribe +
# bedrock:CreateFoundationModelAgreement; if it does not, this prints guidance and
# exits 0 (enable model access manually in the Bedrock console → Model access).
set -uo pipefail

MODELS=(
  "anthropic.claude-sonnet-5-5"
  "anthropic.claude-haiku-4-5-20251001-v1:0"
)
REGIONS=("us-west-2" "us-east-1" "us-east-2")

for MODEL in "${MODELS[@]}"; do
  for REGION in "${REGIONS[@]}"; do
    OFFER=$(aws bedrock list-foundation-model-agreement-offers \
              --model-id "$MODEL" --region "$REGION" \
              --query 'offers[0].offerToken' --output text 2>/tmp/bma_err || true)
    if [ -z "$OFFER" ] || [ "$OFFER" = "None" ]; then
      # No offer token: either already fully subscribed, or the account cannot
      # operate in this region. Probe the invoke-agreement state; treat denial as
      # a skip (non-fatal).
      if grep -qi "AccessDenied" /tmp/bma_err 2>/dev/null; then
        echo "[bedrock-access] $REGION/$MODEL: access denied listing offers (region restricted or missing marketplace perms) — skipping"
      else
        echo "[bedrock-access] $REGION/$MODEL: no offer token (already subscribed?) — skipping"
      fi
      continue
    fi
    OUT=$(aws bedrock create-foundation-model-agreement \
            --model-id "$MODEL" --offer-token "$OFFER" --region "$REGION" 2>&1 || true)
    if echo "$OUT" | grep -qi "already exists"; then
      echo "[bedrock-access] $REGION/$MODEL: agreement already exists — ok"
    elif echo "$OUT" | grep -qi "\"modelId\""; then
      echo "[bedrock-access] $REGION/$MODEL: agreement created — ok"
    else
      echo "[bedrock-access] $REGION/$MODEL: could not subscribe (non-fatal): $(echo "$OUT" | head -c 200)"
    fi
  done
done

echo "[bedrock-access] done. If Claude routes still 403, enable model access for the Claude models listed above in the Bedrock console (Model access) for us-west-2 + us-east-1."
exit 0
