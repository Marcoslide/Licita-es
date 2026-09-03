# Infraestrutura de produção da coleta (Supabase)

Projeto: `sistema-precificacao` (rxcfbbzosbfiwyloqtdk, sa-east-1) — a Bolsa vive no
**schema isolado `bolsa`** (o plano free permite só 2 projetos ativos; nada do schema
`public` existente foi alterado). Para mover a um projeto dedicado depois: rodar as
migrações em `migrations/` no projeto novo, implantar `functions/coleta-pncp` e recriar
os agendamentos de `pg_cron`.

- `migrations/` — schema canônico (raw + normalizado + eventos + operação), grants e cron.
- `functions/coleta-pncp/` — Edge Function (Deno) implantada como versão de produção do
  PncpCollector; grava via conexão direta (`SUPABASE_DB_URL`), pois o PostgREST hospedado
  não expõe o schema `bolsa`.
- Leitura pública: views `public.bolsa_vw_*` (somente SELECT via anon key) — a UI consome
  apenas essas views (o navegador nunca acessa o PNCP, §90).
