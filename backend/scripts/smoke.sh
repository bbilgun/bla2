#!/usr/bin/env bash
# Walks the whole API on a deployed stage with curl: the "is the backend done?" check.
#   ./scripts/smoke.sh you@example.com 'Passw0rd!' [stage]
set -euo pipefail
EMAIL="$1"; PASSWORD="$2"; STAGE="${3:-dev}"
REGION="${AWS_REGION:-ap-northeast-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"

API="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "netzero-${STAGE}" \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiUrl'].OutputValue" --output text)"
TOKEN="$("$HERE/get-token.sh" "$EMAIL" "$PASSWORD" "$STAGE")"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'content-type: application/json')

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);console.log(process.argv[1]?process.argv[1].split(".").reduce((o,k)=>o?.[k],v):JSON.stringify(v,null,2))})' "${1:-}"; }

step "GET /health (no token)"
curl -sf "$API/health" | json

step "GET /me"
ME="$(curl -sf "${AUTH[@]}" "$API/me")"; echo "$ME" | json
MY_ID="$(echo "$ME" | json userId)"

step "GET /me without a token -> 401 from API Gateway"
curl -s -o /dev/null -w '%{http_code}\n' "$API/me"

step "POST /groups"
GROUP_ID="$(curl -sf "${AUTH[@]}" -X POST "$API/groups" -d '{"name":"Smoke test"}' | json id)"; echo "$GROUP_ID"

step "POST /groups/$GROUP_ID/expenses (twice, same Idempotency-Key)"
KEY="smoke-$(date +%s)"
BODY="{\"description\":\"Lunch\",\"amountCents\":10000,\"paidBy\":\"$MY_ID\",\"split\":{\"type\":\"EVEN\",\"userIds\":[\"$MY_ID\"]}}"
curl -sf "${AUTH[@]}" -H "Idempotency-Key: $KEY" -X POST "$API/groups/$GROUP_ID/expenses" -d "$BODY" | json id
curl -si "${AUTH[@]}" -H "Idempotency-Key: $KEY" -X POST "$API/groups/$GROUP_ID/expenses" -d "$BODY" | grep -i 'idempotent-replayed'

step "GET /groups/$GROUP_ID/expenses (should be exactly 1)"
curl -sf "${AUTH[@]}" "$API/groups/$GROUP_ID/expenses" | json items.length

step "GET /groups/$GROUP_ID/balances"
curl -sf "${AUTH[@]}" "$API/groups/$GROUP_ID/balances" | json

step "GET /groups/000000000000000000000000 -> 404 GROUP_NOT_FOUND"
curl -s "${AUTH[@]}" "$API/groups/000000000000000000000000" | json error.code

printf '\n\033[32mSmoke test passed.\033[0m\n'
