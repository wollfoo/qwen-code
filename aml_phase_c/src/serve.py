import subprocess, os, time, signal
from flask import Flask, request, Response
import requests

# Launch vLLM server in background
cmd = [
    "vllm", "serve", os.environ.get("AZUREML_MODEL_DIR", "/var/model"),
    "--dtype", "bf16",                     # phù hợp A100 80GB
    "--tensor-parallel-size", "1",        # 1 GPU
    "--max-model-len", "131072",          # chỉnh theo VRAM thực tế
    "--host", "0.0.0.0", "--port", "8000",
    "--enable-auto-batching"
]
proc = subprocess.Popen(cmd)

app = Flask(__name__)

@app.route('/v1/<path:path>', methods=['GET', 'POST', 'OPTIONS'])
def proxy(path):
    """Proxy tất cả request OpenAI-style sang vLLM backend"""
    try:
        resp = requests.request(
            method=request.method,
            url=f'http://127.0.0.1:8000/v1/{path}',
            headers={k: v for k, v in request.headers if k.lower() != 'host'},
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            stream=True,
            timeout=300,
        )
        return Response(resp.iter_content(chunk_size=8192), resp.status_code, resp.headers.items())
    except requests.exceptions.RequestException as e:
        return Response(str(e), status=500)

@app.route('/', methods=['GET'])
def health():
    return "ok", 200

# Graceful shutdown
@app.route('/shutdown', methods=['POST'])
def shutdown():
    proc.send_signal(signal.SIGTERM)
    return "shutting down", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
