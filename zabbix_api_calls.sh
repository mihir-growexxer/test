#!/bin/bash
set -euo pipefail

############################################
# CONFIG
############################################
ZABBIX_API_URL="https://zabbix.vonagenetworks.net/zabbix/api_jsonrpc.php"

# Zabbix API token
ZABBIX_AUTH_TOKEN="TOKEN"

S3_BUCKET="edw-bigid-external-data-scan-833542145606"
S3_PREFIX="test"        # no trailing slash
AWS_REGION="us-east-1"

############################################
# RUNTIME
############################################
TS="$(date -u +"%Y%m%dT%H%M%SZ")"
WORKDIR="/tmp/zabbix_export_${TS}"
mkdir -p "$WORKDIR"

HOST_FILE="${WORKDIR}/host_get_${TS}.json"
PROXY_FILE="${WORKDIR}/proxy_get_${TS}.json"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' is required but not installed" >&2
    exit 1
  }
}

fail_if_html() {
  local f="$1"
  if head -c 1 "$f" | grep -q '<'; then
    echo "ERROR: Got HTML instead of JSON (SSO redirect / wrong endpoint)" >&2
    head -n 20 "$f" >&2
    exit 1
  fi
}

fail_if_zabbix_error() {
  local f="$1"
  if grep -q '"error"' "$f"; then
    echo "ERROR: Zabbix API returned error:" >&2
    cat "$f" >&2
    exit 1
  fi
}

fail_if_invalid_json() {
  local f="$1"
  jq -e . "$f" >/dev/null 2>&1 || {
    echo "ERROR: Invalid JSON in $f" >&2
    echo "First 20 lines:" >&2
    head -n 20 "$f" >&2
    exit 1
  }
}

post() {
  local payload="$1"
  curl --silent --show-error --fail --location \
    --insecure \
    -H 'Content-Type: application/json-rpc' \
    --data "$payload" \
    "$ZABBIX_API_URL"
}

# Requirements
need_cmd jq
need_cmd curl
need_cmd aws

# Token check
if [[ -z "${ZABBIX_AUTH_TOKEN}" ]]; then
  echo "ERROR: ZABBIX_AUTH_TOKEN is empty. Set it like:" >&2
  echo "  export ZABBIX_AUTH_TOKEN='YOUR_TOKEN_HERE'" >&2
  exit 1
fi

echo "[$TS] Running host.get ..."
post "{
  \"jsonrpc\": \"2.0\",
  \"method\": \"host.get\",
  \"params\": {
    \"output\": [\"hostid\", \"host\"],
    \"selectInterfaces\": [\"interfaceid\", \"ip\"]
  },
  \"id\": 2,
  \"auth\": \"${ZABBIX_AUTH_TOKEN}\"
}" | jq . > "$HOST_FILE"

fail_if_html "$HOST_FILE"
fail_if_zabbix_error "$HOST_FILE"
fail_if_invalid_json "$HOST_FILE"

echo "[$TS] Running proxy.get ..."
post "{
  \"jsonrpc\": \"2.0\",
  \"method\": \"proxy.get\",
  \"params\": {
    \"output\": \"extend\",
    \"selectInterface\": \"extend\"
  },
  \"id\": 3,
  \"auth\": \"${ZABBIX_AUTH_TOKEN}\"
}" | jq . > "$PROXY_FILE"

fail_if_html "$PROXY_FILE"
fail_if_zabbix_error "$PROXY_FILE"
fail_if_invalid_json "$PROXY_FILE"

echo "[$TS] Uploading to S3..."
aws s3 cp "$HOST_FILE"  "s3://${S3_BUCKET}/${S3_PREFIX}/host_get_${TS}.json"  --region "$AWS_REGION"
aws s3 cp "$PROXY_FILE" "s3://${S3_BUCKET}/${S3_PREFIX}/proxy_get_${TS}.json" --region "$AWS_REGION"

echo "[$TS] Done."
echo "Uploaded:"
echo " - s3://${S3_BUCKET}/${S3_PREFIX}/host_get_${TS}.json"
echo " - s3://${S3_BUCKET}/${S3_PREFIX}/proxy_get_${TS}.json"
