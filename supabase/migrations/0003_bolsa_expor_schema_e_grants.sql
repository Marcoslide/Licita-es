-- Exposição do schema bolsa na API REST + grants do service role.
-- Nota de produção: no Supabase hospedado o reload do PostgREST via
-- `alter role authenticator set pgrst.db_schemas` não surtiu efeito nesta
-- instância; por isso a Edge Function grava via conexão direta ao Postgres
-- (SUPABASE_DB_URL) e a leitura pública da UI usa views em `public` (0004).
alter role authenticator set pgrst.db_schemas = 'public, storage, graphql_public, bolsa';
notify pgrst, 'reload config';

grant usage on schema bolsa to service_role;
grant all on all tables in schema bolsa to service_role;
grant usage, select on all sequences in schema bolsa to service_role;
alter default privileges in schema bolsa grant all on tables to service_role;
alter default privileges in schema bolsa grant usage, select on sequences to service_role;
alter default privileges in schema bolsa grant select on tables to anon, authenticated;

update bolsa.coleta_config set params = params || '{"orcamentoMs":35000}'::jsonb;
