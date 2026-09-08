FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
# libgl1-mesa-glx was renamed to libgl1 in Debian bookworm (the base of
# python:3.11-slim), so the old package name 404s on apt-get install.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Keep every cache inside a directory the container can definitely write to.
# Hugging Face Spaces runs with a different HOME than a plain Docker host, and
# torch/HF libraries fall back to writing under HOME on first import.
ENV HOME=/tmp \
    TORCH_HOME=/tmp/torch \
    HF_HOME=/tmp/huggingface \
    XDG_CACHE_HOME=/tmp/cache

# 7860 is the port Hugging Face Spaces expects by default (see app_port in
# README.md). Hosts that inject their own $PORT (Render, Cloud Run) still work
# because the port is read from the environment at start-up.
ENV PORT=7860
EXPOSE 7860

# Shell form on purpose — exec form would pass "${PORT}" through literally
# instead of substituting the environment variable.
CMD uvicorn app:app --host 0.0.0.0 --port ${PORT:-7860}
