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

# Expose port
EXPOSE 8000

# Run server
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
