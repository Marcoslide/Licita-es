FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY pyproject.toml README.md ./
COPY migrations ./migrations
COPY src ./src
COPY scripts ./scripts

RUN pip install --no-cache-dir . \
    && groupadd --gid 10001 licita \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin licita

USER 10001:10001

ENTRYPOINT ["bolsa-coleta"]
CMD ["--db", "/runtime/data/bolsa_licitacoes.db", "serve-admin", "--host", "0.0.0.0", "--port", "8088"]
