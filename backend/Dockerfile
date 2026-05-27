FROM python:3.12-slim

WORKDIR /app

# Install Python deps first so this layer caches across code changes
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Then copy the application code
COPY app/ ./app/

# Create a non-root user and a writable /data dir for SQLite
RUN useradd -m -u 1000 appuser && \
    mkdir -p /data && \
    chown -R appuser:appuser /app /data
USER appuser

# v2: state lives in MySQL. No local volume. DATABASE_URL is injected by k8s Secret.

EXPOSE 8000

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
