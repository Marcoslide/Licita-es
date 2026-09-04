-- ============================================================
-- FASE DE ESTABILIZAÇÃO — P3-B: correção de bug real encontrado ao
-- provar o motor genérico em produção (coleta-pncp).
--
-- Causa raiz confirmada (não é concorrência real — o SELECT...FOR
-- UPDATE já serializa corretamente chamadas concorrentes na mesma
-- chave): uma chamada manual passou p_campos/derivou `dados` como um
-- valor jsonb NÃO-objeto (string escalar contendo o JSON como texto,
-- em vez do objeto). O operador `||` do Postgres, quando um dos lados
-- não é objeto, NÃO faz merge — produz um ARRAY com cada lado como
-- elemento. Isso corrompeu bolsa.estado_atual.dados para 1 linha real
-- (id=52, chave 92411974000186-1-000098/2026, fonte pncp), com a
-- MESMA assinatura do bug já corrigido antes em `detalhe` (v12).
--
-- Correção (2 guardas defensivas, mesma filosofia daquele fix):
-- 1) Rejeita p_campos que não seja objeto jsonb — falha alto na
--    entrada em vez de corromper o estado silenciosamente.
-- 2) Auto-cura: se o `dados` já armazenado (de uma execução anterior
--    a este fix) não for objeto, trata como vazio em vez de propagar/
--    agravar a corrupção no merge seguinte.
-- ============================================================
create or replace function bolsa.registrar_estado(
  p_entidade text, p_chave text, p_fonte_id text, p_campos jsonb,
  p_canonico_id bigint default null, p_confianca numeric default 1.0
) returns jsonb
language plpgsql
security definer
set search_path = public, bolsa
as $function$
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

  if p_campos is not null and jsonb_typeof(p_campos) is distinct from 'object' then
    raise exception 'p_campos deve ser um objeto jsonb (recebido tipo: %)', jsonb_typeof(p_campos);
  end if;

  select id, dados, versao into v_id, v_dados_antes, v_versao
    from bolsa.estado_atual
   where entidade = p_entidade and chave = p_chave and fonte_id = p_fonte_id
   for update;

  if v_dados_antes is not null and jsonb_typeof(v_dados_antes) is distinct from 'object' then
    v_dados_antes := '{}'::jsonb;
  end if;

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
         set dados = (case when jsonb_typeof(dados) = 'object' then dados else '{}'::jsonb end) || p_campos,
             versao = versao + 1,
             canonico_id = coalesce(p_canonico_id, canonico_id),
             atualizado_em = now()
       where id = v_id
       returning versao into v_versao;
    elsif p_canonico_id is not null then
      update bolsa.estado_atual set canonico_id = p_canonico_id, atualizado_em = atualizado_em where id = v_id;
    end if;
  end if;

  if p_canonico_id is not null then
    insert into bolsa.proc_fontes (canonico_id, fonte, tabela, registro_chave)
    values (p_canonico_id, p_fonte_id, 'bolsa.estado_atual', p_chave)
    on conflict (fonte, tabela, registro_chave) do nothing;
  end if;

  return jsonb_build_object('estado_id', v_id, 'versao', v_versao, 'novo', v_novo, 'mudancas', v_mudancas);
end;
$function$;
