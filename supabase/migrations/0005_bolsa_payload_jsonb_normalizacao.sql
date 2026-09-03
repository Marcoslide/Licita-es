-- O driver serializava o payload duas vezes (jsonb do tipo "string").
-- Trigger garante jsonb objeto daqui em diante; UPDATE corrige o legado.
-- Nota: correção de REPRESENTAÇÃO de tipo — o conteúdo permanece idêntico.
create or replace function bolsa.fix_payload() returns trigger
language plpgsql as $$
begin
  if new.source_payload is not null and jsonb_typeof(new.source_payload) = 'string' then
    new.source_payload := (new.source_payload #>> '{}')::jsonb;
  end if;
  return new;
end $$;

create or replace function bolsa.fix_payload_raw() returns trigger
language plpgsql as $$
begin
  if new.payload is not null and jsonb_typeof(new.payload) = 'string' then
    new.payload := (new.payload #>> '{}')::jsonb;
  end if;
  return new;
end $$;

do $$ declare t text;
begin
  foreach t in array array['orgaos','licitacoes','itens','resultados_itens','documentos','contratos'] loop
    execute format('drop trigger if exists fix_payload_trg on bolsa.%I', t);
    execute format('create trigger fix_payload_trg before insert or update on bolsa.%I for each row execute function bolsa.fix_payload()', t);
  end loop;
end $$;
drop trigger if exists fix_payload_trg on bolsa.raw_payloads;
create trigger fix_payload_trg before insert on bolsa.raw_payloads
for each row execute function bolsa.fix_payload_raw();

update bolsa.orgaos set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.licitacoes set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.itens set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.resultados_itens set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.documentos set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.contratos set source_payload = (source_payload #>> '{}')::jsonb where jsonb_typeof(source_payload) = 'string';
update bolsa.raw_payloads set payload = (payload #>> '{}')::jsonb where jsonb_typeof(payload) = 'string';
