Dưới đây là **quy trình end‑to‑end** để host **Qwen/Qwen3-Coder-480B-A35B-Instruct** trên **Azure Machine Learning (AML)** và **xuất API**. Mình chia đúng 3 phase như bạn yêu cầu.

---bash
az login --identity

# Phase A – Tải model về VM cùng region với AML

> Mục tiêu: tránh egress cross‑region, chủ động kiểm soát download, nén/chia nhỏ trước khi đẩy lên AML.

### 1. Chuẩn bị VM “staging”

* Region **trùng** với AML Workspace.

* Attach & mount disk:

```bash
sudo mkfs.ext4 /dev/sdc
sudo mkdir -p /mnt/models
sudo mount /dev/sdc /mnt/models
echo "/dev/sdc /mnt/models ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
```

### 2. Cài công cụ

```bash
sudo apt update && sudo apt install -y git-lfs pigz aria2 python3-pip
pip install --upgrade huggingface_hub==0.23.4
huggingface-cli login   # dán HF token : <YOUR_HF_TOKEN>
```

### 3. Download model từ HF

```bash
export HF_HOME=/mnt/models/hf_cache
mkdir -p /mnt/models/Qwen3Coder480B
huggingface-cli download Qwen/Qwen3-Coder-480B-A35B-Instruct \
  --repo-type model \
  --local-dir /mnt/models/Qwen3Coder480B \
  --local-dir-use-symlinks False \
  --max-workers 8
```

* **Kiểm tra size & checksum**:

```bash
du -sh /mnt/models/Qwen3Coder480B
find /mnt/models/Qwen3Coder480B -type f -exec sha256sum {} \; > /mnt/models/qwen480b.sha256
```

### 4. (Tuỳ chọn) Nén & chia nhỏ để upload nhanh hơn

```bash
cd /mnt/models
tar -I 'pigz -9' -cf qwen3coder480b.tar.gz Qwen3Coder480B
split -b 50G qwen3coder480b.tar.gz qwen3coder480b.tar.gz.part-
```

---

# Phase B – Đẩy model vào AML & Register

Có 2 cách phổ biến:

## Cách 1: Upload vào **Datastore** rồi register “model path”

### 1. Tạo datastore (nếu chưa có)

```bash
az ml datastore create \
  --name modelstore \
  --type azure_blob \
  --account-name <storageAccount> \
  --container-name models \
  --resource-group <rg> --workspace-name <ws>
```

### 2. Upload bằng **azcopy** (nhanh hơn CLI AML)

```bash
# sinh SAS cho container models
az storage container generate-sas \
  --account-name <storageAccount> \
  --name models \
  --permissions rwl \
  --expiry 2099-01-01 \
  -o tsv > sas.txt

SAS=$(cat sas.txt)
azcopy copy "/mnt/models/Qwen3Coder480B" \
  "https://<storageAccount>.blob.core.windows.net/models/Qwen3Coder480B${SAS}" \
  --recursive=true
```

### 3. Register model trong AML

```bash
az ml model create \
  --name qwen3-coder-480b-a35b \
  --type custom \
  --path azureml://datastores/modelstore/paths/Qwen3Coder480B \
  --version 1 \
  --resource-group <rg> --workspace-name <ws>
```

## Cách 2: Upload trực tiếp từ máy staging (ít file)

```bash
az ml model create \
  --name qwen3-coder-480b-a35b \
  --type custom \
  --path /mnt/models/Qwen3Coder480B \
  --version 1 \
  -g <rg> -w <ws>

az ml model create --name qwen3-coder-480b-a35b --type custom --path /mnt/models/Qwen3Coder480B --version 1 -g rg-llm -w ws-kimi

```

*(CLI sẽ zip & upload → chậm hơn và dễ time-out với 2TB; nên ưu tiên Cách 1.)*

---

# Phase C – Triển khai model trên AML và Xuất API

## 0. Chọn chiến lược chạy

* **Full BF16/FP8**: cần **≥4×A100-80GB** hoặc **1×ND96isr\_H100\_v5** (8×H100).
* Nếu **chỉ có NC48ads\_A100\_v4** (1×80 GB): phải **quantize/giảm context/CPU offload**. (Mình vẫn đưa pipeline vLLM chuẩn; bạn chỉnh flag theo tài nguyên thực tế.)

## 1. Tạo Compute (cluster hoặc online instance)

**compute.yml**

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/amlCompute.schema.json
name: qwen480b-cluster
type: amlcompute
size: Standard_ND96isr_H100_v5  # hoặc ND96amsr_A100_v4; nếu chỉ NC48ads thì thay ở đây
min_instances: 0
max_instances: 2
idle_time_before_scale_down: 600
tier: Dedicated
enable_node_public_ip: false
```

```bash
az ml compute create -f compute.yml -g <rg> -w <ws>
```

## 2. Chuẩn bị Environment (Docker image có vLLM)

**Dockerfile**

```Dockerfile
FROM mcr.microsoft.com/azureml/openmpi4.1.0-cuda12.4-cudnn9-ubuntu22.04:latest
RUN pip install --upgrade pip \
 && pip install "torch==2.3.1+cu124" -f https://download.pytorch.org/whl/torch_stable.html \
 && pip install vllm==0.9.0 flash-attn==2.5.8 transformers==4.41.2 safetensors==0.4.3 \
 && pip install huggingface_hub azureml-mlflow requests
ENV HF_HOME=/mnt/models TRANSFORMERS_OFFLINE=1
```

Build & push:

```bash
az acr build -t qwen/vllm:0.9 -r <acr> .
```

**environment.yml**

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/environment.schema.json
name: qwen-vllm-env
version: 1
image: <acr>.azurecr.io/qwen/vllm:0.9
```

```bash
az ml environment create -f environment.yml -g <rg> -w <ws>
```

## 3. Scoring script (serve.py) – proxy OpenAI API

```python
# serve.py
import subprocess, os, time
from flask import Flask, request, Response
import requests

# Start vLLM server
cmd = [
  "vllm", "serve", os.environ["AZUREML_MODEL_DIR"],   # model path mount
  "--dtype", "bf16",                                   # hoặc fp8/int4 tùy
  "--tensor-parallel-size", "8",                       # chỉnh theo GPU
  "--max-model-len", "262144",                         # giảm nếu thiếu VRAM
  "--host", "0.0.0.0", "--port", "8000",
  "--enable-auto-batching"
]
proc = subprocess.Popen(cmd)
time.sleep(10)

app = Flask(__name__)

@app.route('/v1/<path:path>', methods=['GET','POST','OPTIONS'])
def proxy(path):
    resp = requests.request(
        method=request.method,
        url=f'http://127.0.0.1:8000/v1/{path}',
        headers={k:v for k,v in request.headers if k.lower()!="host"},
        data=request.get_data(),
        cookies=request.cookies,
        allow_redirects=False)
    return Response(resp.content, resp.status_code, resp.headers.items())

@app.route('/', methods=['GET'])
def health():
    return "ok", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
```

> Nếu bạn muốn bỏ proxy, đổi `vllm serve` chạy port 80 thẳng và scoring script chỉ trả healthcheck.

## 4. Tạo Online Endpoint & Deployment

**endpoint.yml**

```yaml
name: qwen480b-endpoint
auth_mode: key      # hoặc aml_token / aad_token
```

```bash
az ml online-endpoint create -f endpoint.yml -g <rg> -w <ws>
```

**deployment.yml**

```yaml
name: blue
endpoint_name: qwen480b-endpoint
model: azureml:qwen3-coder-480b-a35b:1
environment: azureml:qwen-vllm-env@1
code_configuration:
  code: .
  scoring_script: serve.py
instance_type: Standard_ND96isr_H100_v5   # hoặc NC48ads_A100_v4
instance_count: 1
request_settings:
  request_timeout_ms: 900000
  max_concurrent_requests_per_instance: 8
liveness_probe:
  initial_delay: 60
  period: 30
  timeout: 10
readiness_probe:
  initial_delay: 60
  period: 30
  timeout: 10
```

Triển khai:

```bash
az ml online-deployment create -f deployment.yml -g <rg> -w <ws>
az ml online-endpoint show -n qwen480b-endpoint -g <rg> -w <ws> --query scoring_uri -o tsv
az ml online-endpoint get-keys -n qwen480b-endpoint -g <rg> -w <ws>
```

## 5. Gọi thử API (OpenAI-compatible)

```bash
ENDPOINT="<scoring_uri>/v1/chat/completions"
KEY="<primaryKey>"

curl -X POST "$ENDPOINT" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"qwen3-coder-480b-a35b",
    "messages":[{"role":"user","content":"Xin chào"}],
    "max_tokens":256
  }'
```

---

## 6. Hardening & Ops (khuyến nghị nhanh)

| Hạng mục        | Gợi ý                                                                                 |
| --------------- | ------------------------------------------------------------------------------------- |
| **Bảo mật**     | Private Link + APIM/Front Door WAF; JWT Auth thay key đơn giản                        |
| **Monitoring**  | Log Analytics + App Insights. GPU metrics: DCGM exporter sidecar → Prometheus/Grafana |
| **Autoscale**   | `min_instances:0`, rule scale-out theo queue length / GPU util                        |
| **Chi phí**     | Tắt endpoint khi idle; batch/offline nếu workload không real-time                     |
| **Tối ưu VRAM** | FP8/INT4 AWQ + `--max-model-len` giảm; `--gpu-memory-utilization` 0.9                 |

---

## 7. Checklist

* [ ] Model đã nằm trong datastore hoặc path local → register ok
* [ ] Environment image build thành công (torch + vLLM)
* [ ] Compute đúng SKU GPU & quota đủ
* [ ] Endpoint up, healthcheck ok
* [ ] Curl test pass, latency/throughput đúng mong đợi
* [ ] Alerting + scale rule cấu hình

---

### Cần gì thêm?

* Terraform/Bicep/AML SDK script full pipeline?
* Ray multi-node template cho NC48ads nhiều node?
* Quantize pipeline (AWQ/GPTQ) & script LMDeploy?
* Tích hợp Prompt Flow / MLflow logging?

Cho mình 3 thông số: **GPU bạn buộc phải dùng, context cần, TPS/latency mục tiêu**, mình tối ưu flag và cung cấp IaC cụ thể ngay.
