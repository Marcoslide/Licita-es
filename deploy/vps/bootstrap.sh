#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/licita-es
install -d -m 0750 -o 10001 -g 10001 /opt/licita-es/runtime/data
install -d -m 0750 -o 10001 -g 10001 /opt/licita-es/runtime/documents

if ! docker network inspect licita-es-proxy >/dev/null 2>&1; then
  docker network create licita-es-proxy >/dev/null
fi

echo "Diretórios persistentes e rede licita-es-proxy preparados."
