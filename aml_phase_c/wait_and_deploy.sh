#!/usr/bin/env bash
set -euo pipefail
RG=rg-llm
WS=ws-kimi
ENV_NAME=qwen-vllm-env
ENV_VER=4
ENDPOINT=qwen480b-endpoint
DEPLOY_FILE=deployment.yml

while true; do
  IMG=$(az ml environment show -n $ENV_NAME -v $ENV_VER -g $RG -w $WS --query image -o tsv || true)
  STATE=$(az ml environment show -n $ENV_NAME -v $ENV_VER -g $RG -w $WS --query build.status -o tsv || true)
  echo "[wait] image='$IMG' buildStatus='$STATE' $(date)"
  if [[ -n "$IMG" ]]; then
    echo "Environment image ready: $IMG"
    break
  fi
  sleep 60
done

# Ensure endpoint exists
az ml online-endpoint show -n $ENDPOINT -g $RG -w $WS >/dev/null 2>&1 || az ml online-endpoint create -f endpoint.yml -g $RG -w $WS

echo "Creating deployment..."
az ml online-deployment create -f $DEPLOY_FILE -g $RG -w $WS
az ml online-endpoint update -n $ENDPOINT --traffic blue=100 -g $RG -w $WS
echo "Done."
