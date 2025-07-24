# 🚀 Hướng dẫn triển khai **aml_phase_c**

Thư mục: `~/QWEN CODE/aml_phase_c`

> Triển khai model **Qwen3-Coder-480B** trên Azure Machine Learning (AML) dạng **online endpoint**.

---

## 0. Tiền đề

| Yêu cầu | Mô tả |
|---------|-------|
| Model | `qwen3-coder-480b-a35b@1` đã *register* trong AML |
| Resource | `Resource Group = rg-llm`, `Workspace = ws-kimi` |
| ACR | Đã có Azure Container Registry, ví dụ `myacr` |
| Azure CLI | Cài `az` + extension `ml`, đã `az login` hoặc `az login --identity` |

---

## 1. Thiết lập biến môi trường
```bash
export RG=rg-llm
export WS=ws-kimi
export ACR=myacr            # thay bằng tên thật (không kèm .azurecr.io)
cd "~/QWEN CODE/aml_phase_c"
```

---

## 2. Build & đẩy Docker image
```bash
az acr build -t qwen/vllm:0.9 -r $ACR .
IMG="$ACR.azurecr.io/qwen/vllm:0.9"
```

---

## 3. Cập nhật `environment.yml`
```bash
sed -i "s|<acr>.azurecr.io/qwen/vllm:0.9|$IMG|" environment.yml
```

---

## 4. Đăng ký Environment
```bash
az ml environment create -f environment.yml -g $RG -w $WS
```

Kiểm tra:
```bash
az ml environment show --name qwen-vllm-env --version 1 -g $RG -w $WS -o table
```

---

## 5. Tạo GPU Compute (nếu chưa có)
```bash
az ml compute create -f compute.yml -g $RG -w $WS
```

Xem trạng thái:
```bash
az ml compute show -n qwen480b-cluster -g $RG -w $WS -o table
```

---

## 6. Chạy script triển khai
```bash
chmod +x deploy_phase_c.sh   # nếu chưa có quyền
./deploy_phase_c.sh
```
Script sẽ:
1. Tạo compute khi cần.
2. Tạo endpoint `qwen480b-endpoint` (auth **key**).
3. Rollout deployment `blue` gắn model, environment, code.
4. Chuyển traffic 100 % về `blue`.

---

## 7. Giám sát rollout
```bash
az ml online-endpoint show      -n qwen480b-endpoint -g $RG -w $WS -o jsonc
az ml online-deployment get-logs -n qwen480b-endpoint -d blue -g $RG -w $WS --tail
```
Khi trạng thái **Healthy**:
```bash
URI=$(az ml online-endpoint show -n qwen480b-endpoint -g $RG -w $WS --query scoring_uri -o tsv)
KEY=$(az ml online-endpoint get-keys -n qwen480b-endpoint -g $RG -w $WS --query primaryKey -o tsv)

curl -X POST "$URI/v1/chat/completions" \
 -H "Authorization: Bearer $KEY" \
 -H "Content-Type: application/json" \
 -d '{"model":"qwen3-coder-480b-a35b","messages":[{"role":"user","content":"Xin chào"}],"max_tokens":64}'
```

---

## 8. Tuỳ chỉnh nhanh
| Thành phần | Cách chỉnh |
|------------|-----------|
| **VRAM** | Giảm `--max-model-len` / chuyển `--dtype fp8` / INT4 AWQ trong `src/serve.py` |
| **Scale** | Sửa `instance_count` & `max_concurrent_requests_per_instance` trong `deployment.yml` |
| **Auth**  | Đổi `auth_mode` thành `aad_token` hoặc `aml_token` trong `endpoint.yml` |

---

## 9. Khắc phục sự cố
| Lỗi | Nguyên nhân / Cách xử lý |
|------|-------------------------|
| `ImagePullBackOff` | VM không kéo được image ↔ kiểm tra RBAC ACR hoặc `az acr login` |
| `CUDA out of memory` | Giảm context, tăng tensor-parallel, dùng quantization |
| Không nhận HTTP 200 | Xem log `online-deployment get-logs` & health check `/` |

---

> **Hoàn tất!** Bạn đã có pipeline tự động hoá Phase C. Nếu cần Terraform/Bicep hoặc tuning sâu hơn, hãy liên hệ.
