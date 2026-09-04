-- ============================================================
-- MOTOR GENÉRICO DE COLETA (Wave 1 — fontes novas) — fecha o gap
-- honestamente reportado no relatório final do PROMPT 01: até aqui,
-- cada conector (coleta-pncp) reimplementava à mão o SELECT "antes",
-- a lista de campos observados e o INSERT em bolsa.eventos. Isso
-- funciona mas não escala para 121+ fontes.
--
-- Este motor dá RAW -> versão -> diff -> proveniência -> evento SEM
-- código específico por portal: qualquer conector novo chama
-- bolsa.registrar_estado(entidade, chave, fonte_id, campos jsonb)
-- e recebe de graça: diff genérico campo-a-campo (compara contra o
-- jsonb salvo da última vez, não uma lista hardcoded), evento por
-- campo alterado em bolsa.eventos (tabela já genérica, reaproveitada
-- sem alteração), histórico de versão anterior preservado, e (se
-- canonico_id for informado) vínculo em bolsa.proc_fontes para
-- permitir cruzamento cross-source pela mesma lógica já usada em
-- resolver_canonico_pncp().
--
-- Escopo honesto: isto NÃO substitui tabelas normalizadas e tipadas
-- por entidade (ex.: uma futura bolsa.sessoes_disputa) — cada
-- conector continua responsável pelo seu modelo de domínio para
-- consulta rápida/tipada. O motor cobre só a parte que se repetia:
-- captura RAW, diff, versionamento e evento.
-- ============================================================

create table if not exists bolsa.estado_atual (
  id bigint generated always as identity primary key,
  entidade text not null,
  chave text not null,
  fonte_id text not null,
  dados jsonb not null default '{}'::jsonb,
  versao integer not null default 1,
  canonico_id bigint references bolsa.proc_canonico(id),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (entidade, chave, fonte_id)
);
create index if not exists estado_atual_entidade_idx on bolsa.estado_atual (entidade, atualizado_em desc);
create index if not exists estado_atual_canonico_idx on bolsa.estado_atual (canonico_id) where canonico_id is not null;
alter table bolsa.estado_atual enable row level security;

create table if not exists bolsa.estado_versoes (
  id bigint generated always as identity primary key,
  estado_id bigint not null references bolsa.estado_atual(id) on delete cascade,
  entidade text not null,
  chave text not null,
  fonte_id text not null,
  dados jsonb not null,
  versao integer not null,
  vigente_ate timestamptz not null default now()
);
create index if not exists estado_versoes_estado_idx on bolsa.estado_versoes (estado_id, versao desc);
alter table bolsa.estado_versoes enable row level security;

-- Núcleo do motor: diff genérico (não há lista de campos por conector —
-- itera sobre as chaves do jsonb recebido e compara com o jsonb salvo).
create or replace function bolsa.registrar_estado(
  p_entidade text,
  p_chave text,
  p_fonte_id text,
  p_campos jsonb,
  p_canonico_id bigint default null,
  p_confianca numeric default 1.0
) returns jsonb
language plpgsql
security definer
set search_path = public, bolsa
as $$
declare
  v_id bigint;
  v_dados_antes jsonb;
  v_versao int;
  v_novo boolean := false;
  v_mudancas jsonb := '[]'::jsonb;
  v_campo text;
  v_antigo jsonb;
  v_novo_val jsonb;
begin
  if p_entidade is null or p_chave is null or p_fonte_id is null then
    raise exception 'entidade, chave e fonte_id são obrigatórios';
  end if;

  select id, dados, versao into v_id, v_dados_antes, v_versao
    from bolsa.estado_atual
   where entidade = p_entidade and chave = p_chave and fonte_id = p_fonte_id
   for update;

  if v_id is null then
    insert into bolsa.estado_atual (entidade, chave, fonte_id, dados, versao, canonico_id)
    values (p_entidade, p_chave, p_fonte_id, coalesce(p_campos, '{}'::jsonb), 1, p_canonico_id)
    returning id, versao into v_id, v_versao;
    v_novo := true;
    insert into bolsa.eventos (entidade, chave, tipo, fonte_id) values (p_entidade, p_chave, 'NOVO_REGISTRO', p_fonte_id);
  else
    for v_campo in select jsonb_object_keys(coalesce(p_campos, '{}'::jsonb)) loop
      v_novo_val := p_campos -> v_campo;
      v_antigo := coalesce(v_dados_antes, '{}'::jsonb) -> v_campo;
      if v_novo_val is distinct from v_antigo then
        insert into bolsa.eventos (entidade, chave, tipo, campo, valor_anterior, valor_novo, fonte_id)
        values (p_entidade, p_chave, upper(v_campo) || '_ALTERADO', v_campo,
                v_antigo #>> '{}', v_novo_val #>> '{}', p_fonte_id);
        v_mudancas := v_mudancas || jsonb_build_object('campo', v_campo, 'de', v_antigo, 'para', v_novo_val);
      end if;
    end loop;

    if jsonb_array_length(v_mudancas) > 0 then
      insert into bolsa.estado_versoes (estado_id, entidade, chave, fonte_id, dados, versao, vigente_ate)
      values (v_id, p_entidade, p_chave, p_fonte_id, coalesce(v_dados_antes, '{}'::jsonb), v_versao, now());

      update bolsa.estado_atual
         set dados = coalesce(dados, '{}'::jsonb) || p_campos,
             versao = versao + 1,
             canonico_id = coalesce(p_canonico_id, canonico_id),
             atualizado_em = now()
       where id = v_id
       returning versao into v_versao;
    elsif p_canonico_id is not null then
      update bolsa.estado_atual set canonico_id = p_canonico_id, atualizado_em = atualizado_em where id = v_id;
    end if;
  end if;

  -- vínculo canônico idempotente (permite view/consulta cross-source
  -- pela mesma bolsa.proc_fontes já usada por resolver_canonico_pncp)
  if p_canonico_id is not null then
    insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave)
    values (p_canonico_id, p_fonte_id, 'bolsa.estado_atual', p_chave)
    on conflict (fonte, tabela, registro_chave) do nothing;
  end if;

  return jsonb_build_object('estado_id', v_id, 'versao', v_versao, 'novo', v_novo, 'mudancas', v_mudancas);
end;
$$;

revoke all on function bolsa.registrar_estado(text,text,text,jsonb,bigint,numeric) from public;
revoke all on function bolsa.registrar_estado(text,text,text,jsonb,bigint,numeric) from anon;
grant execute on function bolsa.registrar_estado(text,text,text,jsonb,bigint,numeric) to service_role;

-- Helper para registrar uma fonte nova em bolsa.fontes (FK exigida por
-- bolsa.raw_payloads.fonte_id) sem precisar de migration manual por
-- conector — idempotente, chamável do próprio conector no primeiro tick.
create or replace function bolsa.garantir_fonte(
  p_id text, p_nome text, p_base_url text, p_capabilities jsonb default '{}'::jsonb
) returns void
language sql
security definer
set search_path = public, bolsa
as $$
  insert into bolsa.fontes (id, nome, base_url, capabilities, status, criado_em)
  values (p_id, p_nome, p_base_url, coalesce(p_capabilities, '{}'::jsonb), 'ativa', now())
  on conflict (id) do nothing;
$$;

revoke all on function bolsa.garantir_fonte(text,text,text,jsonb) from public;
revoke all on function bolsa.garantir_fonte(text,text,text,jsonb) from anon;
grant execute on function bolsa.garantir_fonte(text,text,text,jsonb) to service_role;
