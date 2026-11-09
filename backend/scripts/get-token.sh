#!/usr/bin/env bash
# Prints a Cognito ID token for curl:
#   export TOKEN=$(./scripts/get-token.sh you@example.com 'Passw0rd!')
#   curl -H "Authorization: Bearer $TOKEN" "$API_URL/me"
set -euo pipefail
EMAIL="$1"; PASSWORD="$2"; STAGE="${3:-dev}"
REGION="${AWS_REGION:-ap-northeast-1}"

CLIENT_ID="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "netzero-${STAGE}" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)"

aws cognito-idp initiate-auth --region "$REGION" --client-id "$CLIENT_ID" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$EMAIL",PASSWORD="$PASSWORD" \
  --query 'AuthenticationResult.IdToken' --output text
