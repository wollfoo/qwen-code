FROM mcr.microsoft.com/azureml/openmpi4.1.0-cuda12.4-cudnn9-ubuntu22.04:latest
RUN pip install --upgrade pip \
 && pip install "torch==2.3.1+cu124" -f https://download.pytorch.org/whl/torch_stable.html \
 && pip install vllm==0.9.0 flash-attn==2.5.8 transformers==4.41.2 safetensors==0.4.3 \
 && pip install huggingface_hub azureml-mlflow requests flask
ENV HF_HOME=/mnt/models TRANSFORMERS_OFFLINE=1
