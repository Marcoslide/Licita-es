-- TEMPORÁRIO até haver SMTP próprio: o serviço de e-mail embutido do
-- Supabase tem limite baixíssimo e não entrega de forma confiável, então
-- novos cadastros ficavam presos em "confirme seu e-mail". Este trigger
-- confirma o e-mail no ato do cadastro. QUANDO configurar SMTP próprio
-- (Dashboard → Authentication → Emails → SMTP), reverta com:
--   drop trigger if exists saas_autoconfirma on auth.users;
create or replace function public.saas_autoconfirmar_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is null then
    new.email_confirmed_at := now();
  end if;
  return new;
end $$;
drop trigger if exists saas_autoconfirma on auth.users;
create trigger saas_autoconfirma before insert on auth.users
  for each row execute function public.saas_autoconfirmar_email();
