FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY drift_detector.py .
CMD ["python", "drift_detector.py"]
