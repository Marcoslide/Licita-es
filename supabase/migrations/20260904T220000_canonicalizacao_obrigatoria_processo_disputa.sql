-- PARTE A1 (fechamento Wave 1) — fluxo obrigatório de canonicalização para
-- entidades do motor genérico (entidade='processo_disputa', usado por
-- qualquer fonte nova: bnc, bll, e futuras). Regra do usuário: nunca deixar
-- source_record órfão só porque não existe no PNCP.
--
--   registro novo → tenta match com canonical existente (mesmo órgão CNPJ
--   + mesmo número normalizado em bolsa.licitacoes)
--     0 candidatos  → NEW_CANONICAL_CREATED (cria canônico próprio)
--     1 candidato   → MATCH_EXISTING_CANONICAL (linka ao canônico do PNCP)
--     2+ candidatos → REVIEW_REQUIRED (fila rastreada, não descartada)
--
-- Fila de revisão: canonico_review_pendente. Índice único parcial evita
-- reinserir a mesma pendência a cada execução (idempotência).
create table if not exists bolsa.canonico_review_pendente (
  id bigserial primary key,
  entidade text not null,
  fonte_id text not null,
  chave text not null,
  motivo text not null,
  candidatos jsonb not null default '[]'::jsonb,
  criado_em timestamptz not null default now(),
  resolvido boolean not null default false,
  resolvido_em timestamptz,
  resolvido_canonico_id bigint references bolsa.proc_canonico(id)
);

create unique index if not exists canonico_review_pendente_pendente_uk
  on bolsa.canonico_review_pendente (entidade, fonte_id, chave)
  where not resolvido;

create or replace function bolsa.resolver_canonico_processo_disputa()
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  r record;
  v_orgao_norm text;
  v_numero_digits text;
  v_numero_int numeric;
  v_uf text;
  v_municipio text;
  v_municipio_norm text;
  v_candidatos jsonb;
  v_qtd_candidatos int;
  v_numero_controle text;
  v_canonico_id bigint;
  v_chave_nova text;
  v_match int := 0;
  v_new int := 0;
  v_review int := 0;
  v_erros int := 0;
begin
  for r in
    select e.fonte_id, e.chave, e.dados
    from bolsa.estado_atual e
    where e.entidade = 'processo_disputa'
      and e.canonico_id is null
      and not exists (
        select 1 from bolsa.canonico_review_pendente p
        where p.entidade = e.entidade and p.fonte_id = e.fonte_id and p.chave = e.chave and not p.resolvido
      )
  loop
    begin
      v_orgao_norm := upper(extensions.unaccent(trim(regexp_replace(coalesce(r.dados->>'orgao',''), '\s+', ' ', 'g'))));
      v_numero_digits := regexp_replace(coalesce(r.dados->>'numero',''), '\D', '', 'g');
      v_numero_int := case when v_numero_digits <> '' then v_numero_digits::numeric else null end;

      v_municipio := split_part(coalesce(r.dados->>'cidade_uf',''), '-', 1);
      v_uf := nullif(regexp_replace(coalesce(r.dados->>'cidade_uf',''), '^.*-', ''), '');
      v_municipio_norm := nullif(upper(extensions.unaccent(trim(v_municipio))), '');

      if v_orgao_norm = '' or v_numero_int is null then
        v_chave_nova := 'src:' || r.fonte_id || ':' || r.chave;
        insert into bolsa.proc_canonico (chave_canonica) values (v_chave_nova) on conflict (chave_canonica) do nothing;
        select id into v_canonico_id from bolsa.proc_canonico where chave_canonica = v_chave_nova;
        insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
        values (v_canonico_id, r.fonte_id, 'bolsa.estado_atual', r.chave, null)
        on conflict (fonte, tabela, registro_chave) do nothing;
        update bolsa.estado_atual set canonico_id = v_canonico_id
        where fonte_id = r.fonte_id and entidade = 'processo_disputa' and chave = r.chave;
        v_new := v_new + 1;
        continue;
      end if;

      select jsonb_agg(distinct l.numero_controle_pncp)
      into v_candidatos
      from bolsa.licitacoes l
      join bolsa.orgaos o on o.cnpj = l.orgao_cnpj
      where upper(extensions.unaccent(trim(regexp_replace(o.razao_social, '\s+', ' ', 'g')))) = v_orgao_norm
        and (
          (case when trim(coalesce(l.numero_compra,'')) ~ '^\d+$'
                then trim(l.numero_compra)::numeric = v_numero_int else false end)
          or (case when regexp_replace(coalesce(l.processo,''), '\D', '', 'g') <> ''
                   then regexp_replace(coalesce(l.processo,''), '\D', '', 'g')::numeric = v_numero_int else false end)
        );

      v_qtd_candidatos := coalesce(jsonb_array_length(v_candidatos), 0);

      if v_qtd_candidatos = 0 then
        v_chave_nova := 'proc:' || coalesce(v_uf,'XX') || ':' || coalesce(v_municipio_norm,'?') || ':' || v_numero_int;
        insert into bolsa.proc_canonico (chave_canonica) values (v_chave_nova) on conflict (chave_canonica) do nothing;
        select id into v_canonico_id from bolsa.proc_canonico where chave_canonica = v_chave_nova;
        insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
        values (v_canonico_id, r.fonte_id, 'bolsa.estado_atual', r.chave, null)
        on conflict (fonte, tabela, registro_chave) do nothing;
        update bolsa.estado_atual set canonico_id = v_canonico_id
        where fonte_id = r.fonte_id and entidade = 'processo_disputa' and chave = r.chave;
        v_new := v_new + 1;

      elsif v_qtd_candidatos = 1 then
        v_numero_controle := v_candidatos->>0;
        v_chave_nova := 'pncp:' || v_numero_controle;
        insert into bolsa.proc_canonico (chave_canonica) values (v_chave_nova) on conflict (chave_canonica) do nothing;
        select id into v_canonico_id from bolsa.proc_canonico where chave_canonica = v_chave_nova;
        insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave, url_original)
        values (v_canonico_id, r.fonte_id, 'bolsa.estado_atual', r.chave, null)
        on conflict (fonte, tabela, registro_chave) do nothing;
        update bolsa.estado_atual set canonico_id = v_canonico_id
        where fonte_id = r.fonte_id and entidade = 'processo_disputa' and chave = r.chave;
        v_match := v_match + 1;

      else
        insert into bolsa.canonico_review_pendente (entidade, fonte_id, chave, motivo, candidatos)
        values ('processo_disputa', r.fonte_id, r.chave,
                v_qtd_candidatos || ' processos PNCP do mesmo orgao com o mesmo numero normalizado',
                v_candidatos)
        on conflict (entidade, fonte_id, chave) where not resolvido do nothing;
        v_review := v_review + 1;
      end if;

    exception when others then
      v_erros := v_erros + 1;
    end;
  end loop;

  return jsonb_build_object(
    'match_existing_canonical', v_match,
    'new_canonical_created', v_new,
    'review_required', v_review,
    'erros', v_erros
  );
end;
$function$;
