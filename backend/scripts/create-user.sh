#!/usr/bin/env bash
# Creates a confirmed Cognito user with a permanent password: no email code needed.
# Handy for test accounts and the "second person" in a demo.
#   ./scripts/create-user.sh bat@example.com 'Passw0rd!' 'Bat' [stage]
set -euo pipefail
EMAIL="$1"; PASSWORD="$2"; NAME="${3:-${1%@*}}"; STAGE="${4:-dev}"
REGION="${AWS_REGION:-ap-northeast-1}"

POOL_ID="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "netzero-${STAGE}" \
  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)"

aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL_ID" \
  --username "$EMAIL" --message-action SUPPRESS \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true Name=name,Value="$NAME" >/dev/null

aws cognito-idp admin-set-user-password --region "$REGION" --user-pool-id "$POOL_ID" \
  --username "$EMAIL" --password "$PASSWORD" --permanent

echo "created $EMAIL in $POOL_ID"
