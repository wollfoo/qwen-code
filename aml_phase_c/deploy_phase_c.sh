#!/usr/bin/env bash
set -euo pipefail
RG=rg-llm
WS=ws-kimi

# 1. Create compute if not exists
az ml compute show --name qwen480b-cluster -g $RG -w $WS >/dev/null 2>&1 || az ml compute create -f compute.yml -g $RG -w $WS

# 2. Build docker image & push to ACR (assumes ACR login via az acr build)
# Replace <acr> below before running first time
# az acr build -t qwen/vllm:0.9 -r <acr> .
# az ml environment create -f environment.yml -g $RG -w $WS

# 3. Create endpoint if not exists
az ml online-endpoint show -n qwen480b-endpoint -g $RG -w $WS >/dev/null 2>&1 || az ml online-endpoint create -f endpoint.yml -g $RG -w $WS

# 4. Create deployment (blue) and set traffic 100%
az ml online-deployment create -f deployment.yml -g $RG -w $WS
az ml online-endpoint update -n qwen480b-endpoint --traffic blue=100 -g $RG -w $WS

echo "Deployment submitted. Check status via: az ml online-endpoint show -n qwen480b-endpoint -g $RG -w $WS"
