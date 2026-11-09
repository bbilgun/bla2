#!/usr/bin/env bash
# Walks the whole API on a deployed (non-prod) stage with curl: the "is the backend done?" check.
#   ./scripts/smoke.sh you@example.com 'Passw0rd123' [stage]
#
# Joining a group means invite and accept, which needs a second account. Pass one to test the whole flow:
#   FRIEND_EMAIL=bat@example.com FRIEND_PASSWORD='Passw0rd123' ./scripts/smoke.sh you@example.com 'Passw0rd123'
# Create it with ./scripts/create-user.sh, which marks the email verified. Without a friend, the invite is
# created and cancelled, and the two-person steps are skipped.
#
# Signs in with USER_PASSWORD_AUTH (scripts/get-token.sh), which only non-prod app clients allow.
set -euo pipefail
EMAIL="$1"; PASSWORD="$2"; STAGE="${3:-dev}"
REGION="${AWS_REGION:-ap-northeast-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"

API="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "netzero-${STAGE}" \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiUrl'].OutputValue" --output text)"
TOKEN="$("$HERE/get-token.sh" "$EMAIL" "$PASSWORD" "$STAGE")"
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'content-type: application/json')
FRIEND_AUTH=()
if [[ -n "${FRIEND_EMAIL:-}" ]]; then
  FRIEND_TOKEN="$("$HERE/get-token.sh" "$FRIEND_EMAIL" "$FRIEND_PASSWORD" "$STAGE")"
  FRIEND_AUTH=(-H "Authorization: Bearer $FRIEND_TOKEN" -H 'content-type: application/json')
fi

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
fail() { printf '\033[31mFAILED: %s\033[0m\n' "$1"; exit 1; }
# json [path]: pretty-print stdin, or the value at a dotted path ("items.length", "error.code").
json() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);console.log(process.argv[1]?process.argv[1].split(".").reduce((o,k)=>o?.[k],v):JSON.stringify(v,null,2))})' "${1:-}"; }
# js 'expr': evaluate a JS expression over stdin's JSON as `v`, print the result.
js() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);const r=eval(process.argv[1]);console.log(typeof r==="string"?r:JSON.stringify(r))})' "$1"; }
expect_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1' ($3)"; echo "ok: $3 = $1"; }

step "GET /health (no token)"
curl -sf "$API/health" | json

step "GET /me"
ME="$(curl -sf "${AUTH[@]}" "$API/me")"; echo "$ME" | json
MY_ID="$(echo "$ME" | json userId)"
expect_eq "$(echo "$ME" | json emailVerified)" "true" "emailVerified"

step "GET /me without a token -> 401 from API Gateway"
expect_eq "$(curl -s -o /dev/null -w '%{http_code}' "$API/me")" "401" "status"

step "POST /groups"
GROUP_ID="$(curl -sf "${AUTH[@]}" -X POST "$API/groups" -d '{"name":"Smoke test"}' | json id)"; echo "$GROUP_ID"

if [[ -n "${FRIEND_EMAIL:-}" ]]; then
  step "POST /groups/$GROUP_ID/invites -> $FRIEND_EMAIL, then they accept"
  curl -sf "${AUTH[@]}" -X POST "$API/groups/$GROUP_ID/invites" -d "{\"email\":\"$FRIEND_EMAIL\"}" | json invites
  INVITE_ID="$(curl -sf "${FRIEND_AUTH[@]}" "$API/invites" | js "v.items.find(i => i.groupId === '$GROUP_ID').id")"
  FRIEND_ID="$(curl -sf "${FRIEND_AUTH[@]}" "$API/me" | json userId)"
  MEMBERS="$(curl -sf "${FRIEND_AUTH[@]}" -X POST "$API/groups/$GROUP_ID/invites/$INVITE_ID/accept" | json members.length)"
  expect_eq "$MEMBERS" "2" "members after accept"
  SPLIT_IDS="\"$MY_ID\",\"$FRIEND_ID\""
else
  step "POST /groups/$GROUP_ID/invites, then cancel it (set FRIEND_EMAIL/FRIEND_PASSWORD to test accepting)"
  INVITE_ID="$(curl -sf "${AUTH[@]}" -X POST "$API/groups/$GROUP_ID/invites" -d "{\"email\":\"smoke-$(date +%s)@example.com\"}" | json invites.0.id)"
  expect_eq "$(curl -sf "${AUTH[@]}" -X DELETE "$API/groups/$GROUP_ID/invites/$INVITE_ID" | json invites.length)" "0" "invites after cancel"
  SPLIT_IDS="\"$MY_ID\""
fi

step "POST /groups/$GROUP_ID/expenses (twice, same Idempotency-Key)"
KEY="smoke-$(date +%s)"
BODY="{\"description\":\"Lunch\",\"amountCents\":10000,\"paidBy\":\"$MY_ID\",\"split\":{\"type\":\"EVEN\",\"userIds\":[$SPLIT_IDS]}}"
EXPENSE_ID="$(curl -sf "${AUTH[@]}" -H "Idempotency-Key: $KEY" -X POST "$API/groups/$GROUP_ID/expenses" -d "$BODY" | json id)"
curl -si "${AUTH[@]}" -H "Idempotency-Key: $KEY" -X POST "$API/groups/$GROUP_ID/expenses" -d "$BODY" | grep -i 'idempotent-replayed'

step "GET /groups/$GROUP_ID/expenses (should be exactly 1)"
expect_eq "$(curl -sf "${AUTH[@]}" "$API/groups/$GROUP_ID/expenses" | json items.length)" "1" "expenses"

step "PUT the expense (version 1 -> 2), then again from a stale screen -> 409 EXPENSE_CHANGED"
EDIT="{\"description\":\"Lunch + tip\",\"amountCents\":11000,\"paidBy\":\"$MY_ID\",\"split\":{\"type\":\"EVEN\",\"userIds\":[$SPLIT_IDS]},\"version\":1}"
expect_eq "$(curl -sf "${AUTH[@]}" -X PUT "$API/groups/$GROUP_ID/expenses/$EXPENSE_ID" -d "$EDIT" | json version)" "2" "version"
STALE="${EDIT/Lunch + tip/Dinner}"
expect_eq "$(curl -s "${AUTH[@]}" -X PUT "$API/groups/$GROUP_ID/expenses/$EXPENSE_ID" -d "$STALE" | json error.code)" "EXPENSE_CHANGED" "stale edit"

step "GET /groups/$GROUP_ID/balances"
curl -sf "${AUTH[@]}" "$API/groups/$GROUP_ID/balances" | json

if [[ -n "${FRIEND_EMAIL:-}" ]]; then
  step "The friend can't leave while they owe -> 409 BALANCE_NOT_ZERO"
  expect_eq "$(curl -s "${FRIEND_AUTH[@]}" -X POST "$API/groups/$GROUP_ID/leave" | json error.code)" "BALANCE_NOT_ZERO" "leave"
fi

step "DELETE the expense -> balances back to zero"
expect_eq "$(curl -sf "${AUTH[@]}" -X DELETE "$API/groups/$GROUP_ID/expenses/$EXPENSE_ID" | json deleted)" "true" "deleted"
expect_eq "$(curl -sf "${AUTH[@]}" "$API/groups/$GROUP_ID/balances" | js 'v.balances.every(b => b.netCents === 0)')" "true" "all zero"

if [[ -n "${FRIEND_EMAIL:-}" ]]; then
  step "Now the friend can leave"
  expect_eq "$(curl -sf "${FRIEND_AUTH[@]}" -X POST "$API/groups/$GROUP_ID/leave" | json left)" "true" "left"
fi

step "GET /groups/000000000000000000000000 -> 404 GROUP_NOT_FOUND"
expect_eq "$(curl -s "${AUTH[@]}" "$API/groups/000000000000000000000000" | json error.code)" "GROUP_NOT_FOUND" "stranger's group"

step "DELETE /groups/$GROUP_ID (clean up)"
expect_eq "$(curl -sf "${AUTH[@]}" -X DELETE "$API/groups/$GROUP_ID" | json deleted)" "true" "group deleted"

printf '\n\033[32mSmoke test passed.\033[0m\n'
