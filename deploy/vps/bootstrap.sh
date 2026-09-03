#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/licita-es
install -d -m 0750 -o 10001 -g 10001 /opt/licita-es/runtime/data
install -d -m 0750 -o 10001 -g 10001 /opt/licita-es/runtime/documents

echo "Diretórios persistentes preparados em /opt/licita-es/runtime."
