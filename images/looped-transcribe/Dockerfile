FROM python:3.12-slim-bookworm

# cuBLAS/cuDNN from pip instead of a CUDA base image, in their own layer so code and library bumps don't re-pull them
COPY requirements-cuda.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements-cuda.txt
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.12/site-packages/nvidia/cublas/lib:/usr/local/lib/python3.12/site-packages/nvidia/cudnn/lib

COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY worker.py /app/worker.py
USER 1000
CMD ["python", "-u", "/app/worker.py"]
