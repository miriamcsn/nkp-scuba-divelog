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

# SQLite file path inside the container — on Day 5 this will be a PVC mount
ENV DATABASE_URL=sqlite:////data/divelog.db
VOLUME ["/data"]

EXPOSE 8000

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
