FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 \
    libglib2.0-0 \
    libgomp1 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Constrain numpy<2 globally (Ivy Bridge Xeon doesn't support numpy 2.x X86_V2 baseline)
RUN echo "numpy<2" > /tmp/constraints.txt
ENV PIP_CONSTRAINT=/tmp/constraints.txt

RUN pip install --no-cache-dir numpy==1.24.4

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Remove build tools to save space
ENV PIP_CONSTRAINT=
RUN apt-get purge -y build-essential && apt-get autoremove -y

COPY *.py .

RUN mkdir -p /data/faces

ENV FACE_DB_DIR=/data/faces
ENV RECOGNITION_THRESHOLD=0.45
ENV DETECTION_THRESHOLD=0.5
ENV MODEL_NAME=buffalo_l

EXPOSE 5050

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5050"]
