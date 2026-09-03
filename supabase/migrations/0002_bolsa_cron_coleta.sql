-- Agendamento da coleta contínua (frequências configuráveis — valores iniciais §52)
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table if not exists bolsa.coleta_config (
  job text primary key,
  cron text not null,
  params jsonb not null default '{}'::jsonb,
  ativo boolean not null default true
);
alter table bolsa.coleta_config enable row level security;
grant select on bolsa.coleta_config to anon, authenticated;
create policy leitura_publica on bolsa.coleta_config for select to anon, authenticated using (true);

insert into bolsa.coleta_config (job, cron, params) values
 ('delta','*/20 * * * *','{"job":"delta"}'),
 ('contratos','12 * * * *','{"job":"contratos"}'),
 ('detalhes','8,28,48 * * * *','{"job":"detalhes","maxDetalhes":10}')
on conflict (job) do nothing;

-- Observação: o header usa a chave ANON (publicável por design; a função exige JWT válido).
create or replace function bolsa.disparar_coleta(p_job text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare v_params jsonb; v_id bigint;
begin
  select params into v_params from bolsa.coleta_config where job = p_job and ativo;
  if v_params is null then return null; end if;
  select net.http_post(
    url := 'https://rxcfbbzosbfiwyloqtdk.supabase.co/functions/v1/coleta-pncp',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4Y2ZiYnpvc2JmaXd5bG9xdGRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5MzE4MTEsImV4cCI6MjEwMzUwNzgxMX0.g1hXBzu2dYjyggOPWKVadxgHQRlwQ7ebQqRk4i-Z3F4'),
    body := v_params,
    timeout_milliseconds := 55000
  ) into v_id;
  return v_id;
end $$;

revoke all on function bolsa.disparar_coleta(text) from public, anon, authenticated;

select cron.schedule('bolsa_delta',     '*/20 * * * *',   $$select bolsa.disparar_coleta('delta')$$);
select cron.schedule('bolsa_contratos', '12 * * * *',     $$select bolsa.disparar_coleta('contratos')$$);
select cron.schedule('bolsa_detalhes',  '8,28,48 * * * *',$$select bolsa.disparar_coleta('detalhes')$$);
