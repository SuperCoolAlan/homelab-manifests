FROM python:3.12-slim-bookworm

# cuBLAS/cuDNN from pip instead of a CUDA base image; ctranslate2 4.x needs CUDA 12 + cuDNN 9
RUN pip install --no-cache-dir faster-whisper==1.2.1 boto3==1.43.108 prometheus-client==0.26.0 \
    nvidia-cublas-cu12==12.9.2.10 nvidia-cudnn-cu12==9.27.0.42
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.12/site-packages/nvidia/cublas/lib:/usr/local/lib/python3.12/site-packages/nvidia/cudnn/lib

COPY worker.py /app/worker.py
USER 1000
CMD ["python", "-u", "/app/worker.py"]
