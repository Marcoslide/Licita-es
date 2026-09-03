# Relatório de deploy na VPS — 2026-09-02

## Resultado

O ambiente de staging da Bolsa de Licitações foi instalado em `/opt/licita-es`, com coleta real agendada, armazenamento persistente e publicação em `https://bolsa.frontlinetec.com.br`.

- API administrativa: contêiner isolado, exposto apenas no loopback da VPS e protegido por token.
- Scheduler: contêiner dedicado para as coletas periódicas.
- Web: contêiner dedicado, publicado pelo Nginx compartilhado.
- TLS: certificado Let's Encrypt ativo, com renovação pelo timer existente do Certbot.
- DNS: registro A do subdomínio apontado para a VPS.
- Persistência: banco e documentos em `/opt/licita-es/runtime`.

## Isolamento do proxy

A rede `licita-es-proxy` liga exclusivamente o Nginx compartilhado ao frontend `licita-es-web`. A rede `licita-es-internal` continua reservada para API, scheduler e frontend. Isso impede colisões com aliases genéricos de outros projetos da VPS.

Durante a instalação foi detectada uma colisão preexistente no alias Docker `api`. O upstream do domínio `api.frontlinetec.com.br` foi tornado explícito como `orbita-vps-api-1:4000`, com backup da configuração anterior. Apó a correção, a API e os demais domínios existentes deixaram de apresentar erro 502.

## Coleta inicial

A primeira execução real consolidou 36 registros brutos, 10 licitações, 10 contratos, 9 órgãos, 9 unidades e 22 vínculos de origem. Três erros registrados correspondem à tentativa inicial sem saída DNS; foram mantidos como trilha de auditoria. As execuções seguintes do PNCP e Compras foram concluídas com sucesso.

## Limitações atuais

- A interface publicada ainda é o protótipo estático e não consome a API administrativa.
- O staging usa SQLite; a migração para PostgreSQL permanece como etapa de endurecimento para produção.
- Ainda falta configurar backup externo específico dos dados da Bolsa, monitoramento e regras de firewall da Hostinger após mapear todas as portas legadas.
- A VPS está com uso de disco elevado; qualquer limpeza de imagens Docker deve ser aprovada separadamente para preservar opções de rollback.
