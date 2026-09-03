create table if not exists bolsa.arp_saldos (
  id bigint generated always as identity primary key,
  fonte_id text not null default 'compras_gov',
  numero_ata text not null,
  unidade_gerenciadora text not null,
  chave_dedup text not null,
  numero_item int,
  catalogo_codigo text,
  quantidade_registrada numeric,
  quantidade_empenhada numeric,
  saldo numeric,
  valor_unitario numeric,
  source_payload jsonb not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (numero_ata, unidade_gerenciadora, chave_dedup)
);
alter table bolsa.arp_saldos enable row level security;
create policy leitura_publica on bolsa.arp_saldos for select to anon, authenticated using (true);
create trigger fix_payload_trg before insert or update on bolsa.arp_saldos
for each row execute function bolsa.fix_payload();

-- disparador genérico por fonte (o header usa a chave ANON, publicável por design)
create or replace function bolsa.disparar_fonte(p_funcao text, p_job text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_params jsonb; v_id bigint;
begin
  select params into v_params from bolsa.coleta_config where job = p_job and ativo;
  if v_params is null then return null; end if;
  select net.http_post(
    url := 'https://rxcfbbzosbfiwyloqtdk.supabase.co/functions/v1/' || p_funcao,
    headers := jsonb_build_object('Content-Type','application/json',
      'Authorization','Bearer <ANON_KEY_DO_PROJETO>'),
    body := v_params, timeout_milliseconds := 55000) into v_id;
  return v_id;
end $$;
revoke all on function bolsa.disparar_fonte(text, text) from public, anon, authenticated;

insert into bolsa.coleta_config (job, cron, params) values
 ('comprasgov_arp_saldo','23 */4 * * *','{"job":"arp_saldo","orcamentoMs":35000}')
on conflict (job) do nothing;

select cron.schedule('bolsa_pncp_atas',      '37 */2 * * *', $$select bolsa.disparar_fonte('coleta-pncp-planos','pncp_atas')$$);
select cron.schedule('bolsa_pncp_pca',       '52 6 * * *',   $$select bolsa.disparar_fonte('coleta-pncp-planos','pncp_pca')$$);
select cron.schedule('bolsa_cg_catalogo',    '18 * * * *',   $$select bolsa.disparar_fonte('coleta-comprasgov','comprasgov_catalogo')$$);
select cron.schedule('bolsa_cg_precos',      '33 */2 * * *', $$select bolsa.disparar_fonte('coleta-comprasgov','comprasgov_precos')$$);
select cron.schedule('bolsa_cg_arp_saldo',   '23 */4 * * *', $$select bolsa.disparar_fonte('coleta-comprasgov','comprasgov_arp_saldo')$$);
select cron.schedule('bolsa_contratosgov',   '7 */3 * * *',  $$select bolsa.disparar_fonte('coleta-contratosgov','contratosgov')$$);
select cron.schedule('bolsa_transparencia',  '47 */6 * * *', $$select bolsa.disparar_fonte('coleta-transparencia','transparencia')$$);
