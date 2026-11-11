#!/usr/bin/env bash
#
# Load the synthetic order dataset into the DynamoDB orders table.
#
# Reads a JSON array of DynamoDB-marshalled items (terraform/data/orders.json),
# chunks it into batches of 25 (the batch-write-item limit), and writes each
# batch with `aws dynamodb batch-write-item`. PutRequest is an upsert, so
# re-running is idempotent (same keys overwritten, never duplicated).
# UnprocessedItems (throttling) are retried with capped exponential backoff.
#
# Usage:
#   load_orders.sh <table_name> <region> <orders_json_path>
#
# Invoked by null_resource.load_orders in terraform/dynamodb.tf.

set -euo pipefail

TABLE="${1:?table name required}"
REGION="${2:?region required}"
DATA_FILE="${3:?orders.json path required}"

if [[ ! -f "$DATA_FILE" ]]; then
  echo "ERROR: data file not found: $DATA_FILE" >&2
  exit 1
fi

BATCH_SIZE=25
MAX_RETRIES=6

total="$(jq 'length' "$DATA_FILE")"
echo "Loading ${total} orders into table '${TABLE}' (${REGION}) in batches of ${BATCH_SIZE}..."

loaded=0
offset=0

while (( offset < total )); do
  # Slice out the next BATCH_SIZE items and wrap each as a PutRequest under the
  # table name — the exact shape batch-write-item's --request-items expects.
  request_items="$(
    jq -c --arg table "$TABLE" --argjson off "$offset" --argjson n "$BATCH_SIZE" \
      '{ ($table): ( .[$off:($off+$n)] | map({ PutRequest: { Item: . } }) ) }' \
      "$DATA_FILE"
  )"

  batch_count="$(jq -r --arg table "$TABLE" '.[$table] | length' <<<"$request_items")"

  attempt=0
  while :; do
    # batch-write-item echoes any items it couldn't write back in UnprocessedItems.
    # Capture the FULL response (NOT --query 'UnprocessedItems'): on a fully
    # successful batch the AWS CLI omits UnprocessedItems, and a --query
    # projection of the absent key prints an EMPTY STRING (not {} or null),
    # which broke the guard below and pushed every batch into a bogus retry with
    # empty --request-items. The full response is always valid JSON, so jq can
    # extract UnprocessedItems (defaulting to {} when absent).
    response="$(
      aws dynamodb batch-write-item \
        --region "$REGION" \
        --request-items "$request_items" \
        --output json
    )"
    unprocessed="$(jq -c '.UnprocessedItems // {}' <<<"$response")"

    # No unprocessed items (either null or an empty object) -> batch done.
    if [[ "$unprocessed" == "null" || "$unprocessed" == "{}" ]]; then
      break
    fi

    attempt=$(( attempt + 1 ))
    if (( attempt > MAX_RETRIES )); then
      echo "ERROR: batch at offset ${offset} still had unprocessed items after ${MAX_RETRIES} retries" >&2
      exit 1
    fi

    # Retry only what wasn't processed, with capped exponential backoff.
    request_items="$unprocessed"
    sleep_secs=$(( 2 ** (attempt - 1) ))
    echo "  batch offset ${offset}: retrying unprocessed items (attempt ${attempt}, sleep ${sleep_secs}s)"
    sleep "$sleep_secs"
  done

  loaded=$(( loaded + batch_count ))
  offset=$(( offset + BATCH_SIZE ))
done

echo "${loaded} orders loaded into '${TABLE}'."
