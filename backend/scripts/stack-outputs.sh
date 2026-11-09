#!/usr/bin/env bash
# Prints the deployed stack's outputs (API URL, Cognito ids, bucket) and writes mobile/env/<stage>.json.
#   ./scripts/stack-outputs.sh [stage]
set -euo pipefail
STAGE="${1:-dev}"
REGION="${AWS_REGION:-ap-northeast-1}"
STACK="netzero-${STAGE}"
HERE="$(cd "$(dirname "$0")" && pwd)"

out() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

API_URL="$(out HttpApiUrl)"
POOL_ID="$(out UserPoolId)"
CLIENT_ID="$(out UserPoolClientId)"
BUCKET="$(out ReceiptsBucketName)"

echo "API_URL=$API_URL"
echo "USER_POOL_ID=$POOL_ID"
echo "USER_POOL_CLIENT_ID=$CLIENT_ID"
echo "RECEIPTS_BUCKET=$BUCKET"

ENV_FILE="$HERE/../../mobile/env/${STAGE}.json"
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<EOF
{
  "API_URL": "$API_URL",
  "COGNITO_REGION": "$REGION",
  "COGNITO_USER_POOL_ID": "$POOL_ID",
  "COGNITO_CLIENT_ID": "$CLIENT_ID"
}
EOF
echo "wrote $ENV_FILE"
