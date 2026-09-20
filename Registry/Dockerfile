FROM python:3.11-slim

WORKDIR /app

# Copies before source so `pip install` is only re-run when dependencies
# actually change, not on every code edit.
COPY pyproject.toml README.md ./
COPY tipme_registry ./tipme_registry
RUN pip install --no-cache-dir .

# REGISTRY_DATABASE_PATH and REGISTRY_PHOTOS_DIR should point under /data --
# see fly.toml, which mounts a persistent volume there. Without that, every
# deploy would start from an empty database, taking out every account and
# balance it holds.
RUN mkdir -p /data

EXPOSE 8000
CMD ["uvicorn", "tipme_registry.app:app", "--host", "0.0.0.0", "--port", "8000"]
