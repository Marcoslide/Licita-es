#!/usr/bin/env bash
set -euo pipefail

proxy_network="licita-es-proxy"
web_container="licita-es-web-1"
nginx_container="orbita-vps-nginx-1"
project_root="${LICITA_PROJECT_ROOT:-/opt/licita-es/app}"
vhost_source="${project_root}/deploy/vps/proxy/bolsa.https.conf"
vhost_target="/etc/nginx/conf.d/bolsa.conf"

for container in "${web_container}" "${nginx_container}"; do
  docker inspect "${container}" >/dev/null
done

test -f "${vhost_source}"

if ! docker network inspect "${proxy_network}" >/dev/null 2>&1; then
  docker network create "${proxy_network}" >/dev/null
fi

if ! docker network inspect "${proxy_network}" --format '{{range .Containers}}{{println .Name}}{{end}}' | grep -Fxq "${web_container}"; then
  docker network connect --alias licita-es-web "${proxy_network}" "${web_container}"
fi

if ! docker network inspect "${proxy_network}" --format '{{range .Containers}}{{println .Name}}{{end}}' | grep -Fxq "${nginx_container}"; then
  docker network connect "${proxy_network}" "${nginx_container}"
fi

docker cp "${vhost_source}" "${nginx_container}:${vhost_target}"
docker exec "${nginx_container}" nginx -t
docker exec "${nginx_container}" nginx -s reload

echo "Proxy HTTPS da Bolsa instalado e recarregado com sucesso."
