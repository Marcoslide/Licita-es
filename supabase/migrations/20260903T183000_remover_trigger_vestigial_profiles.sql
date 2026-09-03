-- Auditoria dos triggers de auth.users encontrou três handlers; um deles
-- (trg_auth_user_created -> handle_new_user, inserindo em public.profiles)
-- era resquício do protótipo antigo: nenhuma tela ou função atual lê
-- public.profiles, e um AFTER INSERT que falhe derruba o cadastro inteiro.
-- Removido o trigger; a tabela public.profiles e suas linhas ficam intactas.
-- Teste real de ponta a ponta executado antes e depois: signup via
-- /auth/v1/signup retorna sessão imediata (auto-confirmação ativa),
-- saas_perfis + saas_assinaturas (plano explorar) + saas_eventos criados.
drop trigger if exists trg_auth_user_created on auth.users;
