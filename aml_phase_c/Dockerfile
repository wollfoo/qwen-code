FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y \
    && apt-get install -y python3-pip \
    && ln -s /usr/bin/pip3 /usr/bin/pip \
    && pip install --upgrade pip \
    && pip install "torch==2.3.1+cu124" -f https://download.pytorch.org/whl/torch_stable.html \
    && pip install vllm==0.9.0 transformers==4.41.2 safetensors==0.4.3 \
    && pip install huggingface_hub azureml-mlflow requests flask \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
ENV HF_HOME=/mnt/models TRANSFORMERS_OFFLINE=1
