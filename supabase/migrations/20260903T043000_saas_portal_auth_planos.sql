-- ============================================================
-- BOLSA DE LICITAÇÕES — Camada comercial SaaS (portal)
-- Aplicada em 2026-09-03 no projeto rxcfbbzosbfiwyloqtdk.
-- Tabelas em public com prefixo saas_ (REST imediato + RLS),
-- sem tocar no schema bolsa nem nas tabelas existentes do projeto.
-- Auth: Supabase Auth (auth.users) + perfil por trigger.
-- Nenhum preço/limite hardcodado na aplicação (§119): tudo aqui.
-- ============================================================

-- ---------- perfis (1:1 com auth.users) ----------
create table public.saas_perfis (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nome text,
  sobrenome text,
  telefone text,
  papel text not null default 'cliente' check (papel in ('cliente','admin')),
  papel_admin text check (papel_admin in ('super_admin','financeiro','suporte','comercial','operacao_dados','produto')),
  onboarding jsonb not null default '{}'::jsonb,     -- interesses, regiões, temas (opcional, não limita a base)
  aceitou_termos_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- ---------- planos (100% editáveis pelo admin; preços provisórios §38) ----------
create table public.saas_planos (
  id text primary key,                                -- slug: explorar, profissional, inteligencia, business, enterprise
  nome text not null,
  descricao text,
  destaque boolean not null default false,            -- "Mais escolhido" configurável (§98)
  preco_mensal numeric,                               -- null = sob consulta (enterprise)
  preco_anual numeric,                                -- valor/ano já com desconto
  trial_dias int not null default 0,
  ordem int not null default 0,
  ativo boolean not null default true,
  entitlements jsonb not null default '{}'::jsonb,    -- backend de recursos (§42)
  atualizado_em timestamptz not null default now()
);

insert into public.saas_planos (id, nome, descricao, destaque, preco_mensal, preco_anual, trial_dias, ordem, entitlements) values
 ('explorar','Explorar','Conheça o mercado público com acesso gratuito limitado.',false,0,0,0,1,
  '{"pesquisas_dia":10,"max_watchlists":3,"history_days":30,"can_view_competitors":false,"can_export":false,"can_use_ai":false,"max_users":1,"api_access":false}'::jsonb),
 ('profissional','Profissional','A Bolsa completa para quem vende ao governo.',false,297,2970,7,2,
  '{"pesquisas_dia":200,"max_watchlists":10,"history_days":365,"can_view_competitors":false,"can_export":false,"can_use_ai":false,"max_users":1,"api_access":false}'::jsonb),
 ('inteligencia','Inteligência','Concorrentes, rankings, market share e histórico profundo.',true,597,5970,7,3,
  '{"pesquisas_dia":1000,"max_watchlists":30,"history_days":1825,"can_view_competitors":true,"can_export":true,"can_use_ai":"quando_disponivel","max_users":3,"api_access":false}'::jsonb),
 ('business','Business','Equipes, dashboards executivos e uso intensivo.',false,997,9970,7,4,
  '{"pesquisas_dia":5000,"max_watchlists":100,"history_days":1825,"can_view_competitors":true,"can_export":true,"can_use_ai":"quando_disponivel","max_users":10,"api_access":"futuro"}'::jsonb),
 ('enterprise','Enterprise','Alto volume, integrações, SLA e onboarding dedicado.',false,null,null,0,5,
  '{"sob_consulta":true}'::jsonb);

-- ---------- assinaturas (status rico, nunca boolean §31) ----------
create table public.saas_assinaturas (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  plano_id text not null references public.saas_planos(id),
  status text not null default 'ativa' check (status in
    ('trial','ativa','pagamento_pendente','vencida','inadimplente','cancelada',
     'suspensa','cortesia','vitalicia','enterprise','teste_interno')),
  ciclo text not null default 'mensal' check (ciclo in ('mensal','anual')),
  cancelar_no_fim boolean not null default false,     -- cancel_at_period_end (§47)
  inicio timestamptz not null default now(),
  fim_periodo timestamptz,
  trial_fim timestamptz,
  gateway text not null default 'manual',             -- camada PaymentProvider desacoplada (§48); 'manual' até integrar
  gateway_ref text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index saas_ass_user_idx on public.saas_assinaturas (user_id, criado_em desc);
create index saas_ass_status_idx on public.saas_assinaturas (status);

-- ---------- faturas (estrutura pronta; gateway na 2ª entrega §113) ----------
create table public.saas_faturas (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  assinatura_id bigint references public.saas_assinaturas(id),
  valor numeric not null,
  status text not null default 'aberta' check (status in ('aberta','paga','falhou','estornada','cancelada')),
  periodo_inicio date, periodo_fim date,
  vencimento date, pago_em timestamptz,
  gateway text default 'manual', gateway_ref text,
  criado_em timestamptz not null default now()
);
create index saas_fat_user_idx on public.saas_faturas (user_id, criado_em desc);

-- ---------- uso / limites (§43) ----------
create table public.saas_uso (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  metrica text not null,                              -- pesquisas, exports, ia, alertas, api...
  dia date not null default current_date,
  quantidade int not null default 0,
  unique (user_id, metrica, dia)
);

-- ---------- eventos de produto/funil + UTM (§56-57, §101) ----------
create table public.saas_eventos (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  tipo text not null,
  dados jsonb not null default '{}'::jsonb,
  utm jsonb,
  criado_em timestamptz not null default now()
);
create index saas_ev_tipo_idx on public.saas_eventos (tipo, criado_em desc);

-- ---------- leads comerciais (§75-76) ----------
create table public.saas_leads (
  id bigint generated always as identity primary key,
  nome text not null,
  email text not null,
  telefone text,
  empresa text,
  mensagem text,
  origem text default 'landing',
  utm jsonb,
  status text not null default 'novo' check (status in ('novo','contato','demonstracao','negociacao','convertido','perdido')),
  responsavel text,
  criado_em timestamptz not null default now()
);

-- ---------- cupons (§53) ----------
create table public.saas_cupons (
  codigo text primary key,
  tipo text not null check (tipo in ('percentual','fixo')),
  valor numeric not null,
  meses int,                                          -- desconto por X meses (null = sempre)
  max_usos int,
  usados int not null default 0,
  plano_id text references public.saas_planos(id),
  valido_ate date,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- ---------- avisos / conteúdo sem deploy (§70-71) ----------
create table public.saas_avisos (
  id bigint generated always as identity primary key,
  tipo text not null default 'informacao' check (tipo in ('informacao','novidade','manutencao','alerta')),
  titulo text not null,
  corpo text,
  publico jsonb not null default '{"todos":true}'::jsonb,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- ---------- feature flags (§64) ----------
create table public.saas_flags (
  chave text primary key,                             -- AI_EDITAL, PRICE_TO_WIN, COMPETITOR_ANALYSIS...
  descricao text,
  estagio text not null default 'em_breve' check (estagio in ('disponivel','beta','em_breve','desativada')),
  liberacao jsonb not null default '{"todos":false}'::jsonb,  -- planos/usuários/percentual
  atualizado_em timestamptz not null default now()
);
insert into public.saas_flags (chave, descricao, estagio) values
 ('HEATMAP','Mapa de calor do mercado público','disponivel'),
 ('HISTORICO_OBJETO','Histórico por objeto','disponivel'),
 ('COMPETITOR_ANALYSIS','Inteligência de concorrentes','beta'),
 ('AI_EDITAL','Análise de edital por IA','em_breve'),
 ('PRICE_TO_WIN','Price to Win','em_breve');

-- ---------- auditoria administrativa (§83) ----------
create table public.saas_auditoria_admin (
  id bigint generated always as identity primary key,
  admin_id uuid references auth.users(id),
  acao text not null,
  alvo text,
  antes jsonb, depois jsonb,
  motivo text,
  criado_em timestamptz not null default now()
);

-- ============================================================
-- FUNÇÕES
-- ============================================================

create or replace function public.saas_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.saas_perfis where user_id = auth.uid() and papel = 'admin');
$$;

-- perfil + assinatura Explorar criados automaticamente no signup
create or replace function public.saas_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.saas_perfis (user_id, nome, sobrenome, telefone, aceitou_termos_em)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome',''),
          coalesce(new.raw_user_meta_data->>'sobrenome',''),
          new.raw_user_meta_data->>'telefone',
          case when (new.raw_user_meta_data->>'aceitou_termos') = 'true' then now() end)
  on conflict (user_id) do nothing;
  insert into public.saas_assinaturas (user_id, plano_id, status) values (new.id, 'explorar', 'ativa');
  insert into public.saas_eventos (user_id, tipo, utm)
  values (new.id, 'signup_completed', new.raw_user_meta_data->'utm');
  return new;
end $$;
drop trigger if exists saas_on_auth_user_created on auth.users;
create trigger saas_on_auth_user_created
after insert on auth.users for each row execute function public.saas_handle_new_user();

-- cliente não pode se autopromover (escalação de privilégio)
create or replace function public.saas_protege_papel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.saas_is_admin() then
    new.papel := old.papel;
    new.papel_admin := old.papel_admin;
  end if;
  new.atualizado_em := now();
  return new;
end $$;
create trigger saas_perfis_protege before update on public.saas_perfis
for each row execute function public.saas_protege_papel();

-- evento de produto/funil (chamável pelo front, autenticado ou anônimo)
create or replace function public.saas_registrar_evento(p_tipo text, p_dados jsonb default '{}'::jsonb, p_utm jsonb default null)
returns void language sql security definer set search_path = public as $$
  insert into public.saas_eventos (user_id, tipo, dados, utm)
  values (auth.uid(), left(p_tipo, 64), coalesce(p_dados, '{}'::jsonb), p_utm);
$$;
grant execute on function public.saas_registrar_evento(text, jsonb, jsonb) to anon, authenticated;

-- plano efetivo + entitlements do usuário logado
create or replace function public.saas_meu_acesso()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object(
      'plano_id', a.plano_id, 'plano_nome', p.nome, 'status', a.status,
      'ciclo', a.ciclo, 'trial_fim', a.trial_fim, 'fim_periodo', a.fim_periodo,
      'cancelar_no_fim', a.cancelar_no_fim, 'entitlements', p.entitlements)
    from public.saas_assinaturas a join public.saas_planos p on p.id = a.plano_id
    where a.user_id = auth.uid()
    order by a.criado_em desc limit 1
  ), '{}'::jsonb);
$$;
grant execute on function public.saas_meu_acesso() to authenticated;

-- métricas do painel admin (negócio + produto + operação de dados)
create or replace function public.saas_metricas_admin()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.saas_is_admin() then
    raise exception 'acesso restrito a administradores';
  end if;
  select jsonb_build_object(
    'mrr', coalesce((select sum(case a.ciclo when 'anual' then coalesce(p.preco_anual,0)/12.0 else coalesce(p.preco_mensal,0) end)
             from public.saas_assinaturas a join public.saas_planos p on p.id = a.plano_id
             where a.status in ('ativa') and coalesce(p.preco_mensal,0) > 0), 0),
    'clientes', jsonb_build_object(
      'total', (select count(distinct user_id) from public.saas_assinaturas),
      'pagantes', (select count(*) from public.saas_assinaturas a join public.saas_planos p on p.id=a.plano_id where a.status='ativa' and coalesce(p.preco_mensal,0)>0),
      'gratuitos', (select count(*) from public.saas_assinaturas a where a.plano_id='explorar' and a.status='ativa'),
      'trials', (select count(*) from public.saas_assinaturas where status='trial'),
      'inadimplentes', (select count(*) from public.saas_assinaturas where status in ('inadimplente','pagamento_pendente','vencida')),
      'cancelados', (select count(*) from public.saas_assinaturas where status='cancelada'),
      'novos_hoje', (select count(*) from auth.users where created_at::date = current_date)),
    'leads', jsonb_build_object(
      'total', (select count(*) from public.saas_leads),
      'novos', (select count(*) from public.saas_leads where status='novo')),
    'eventos_7d', (select count(*) from public.saas_eventos where criado_em > now() - interval '7 days'),
    'operacao', jsonb_build_object(
      'licitacoes', (select count(*) from bolsa.licitacoes),
      'valor_estimado', (select sum(valor_total_estimado) from bolsa.licitacoes),
      'atas', (select count(*) from bolsa.atas),
      'pca_itens', (select count(*) from bolsa.pca_itens),
      'contratos_gov', (select count(*) from bolsa.contratos_gov),
      'fontes_ativas', (select count(*) from bolsa.fontes where status='ATIVA'),
      'fontes_total', (select count(*) from bolsa.fontes),
      'erros_24h', (select coalesce(sum(erros),0) from bolsa.coleta_log where iniciado_em > now() - interval '24 hours'),
      'execucoes_24h', (select count(*) from bolsa.coleta_log where iniciado_em > now() - interval '24 hours'),
      'ultima_coleta', (select max(iniciado_em) from bolsa.coleta_log))
  ) into r;
  return r;
end $$;
grant execute on function public.saas_metricas_admin() to authenticated;

-- ações administrativas com auditoria obrigatória (§61/§83)
create or replace function public.saas_admin_alterar_assinatura(
  p_user uuid, p_plano text, p_status text, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare v_antes jsonb;
begin
  if not public.saas_is_admin() then
    raise exception 'acesso restrito a administradores';
  end if;
  select to_jsonb(a) into v_antes from public.saas_assinaturas a
   where a.user_id = p_user order by a.criado_em desc limit 1;
  update public.saas_assinaturas
     set plano_id = coalesce(p_plano, plano_id),
         status = coalesce(p_status, status),
         atualizado_em = now()
   where id = (select id from public.saas_assinaturas where user_id = p_user order by criado_em desc limit 1);
  insert into public.saas_auditoria_admin (admin_id, acao, alvo, antes, depois, motivo)
  values (auth.uid(), 'alterar_assinatura', p_user::text, v_antes,
          jsonb_build_object('plano', p_plano, 'status', p_status), p_motivo);
end $$;
grant execute on function public.saas_admin_alterar_assinatura(uuid, text, text, text) to authenticated;

-- consumo de limite (§43) — incrementa e devolve total do dia
create or replace function public.saas_consumir(p_metrica text, p_qtd int default 1)
returns int language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into public.saas_uso (user_id, metrica, quantidade)
  values (auth.uid(), left(p_metrica, 40), p_qtd)
  on conflict (user_id, metrica, dia) do update set quantidade = saas_uso.quantidade + p_qtd
  returning quantidade into v;
  return v;
end $$;
grant execute on function public.saas_consumir(text, int) to authenticated;

-- ============================================================
-- RLS
-- ============================================================
alter table public.saas_perfis enable row level security;
alter table public.saas_planos enable row level security;
alter table public.saas_assinaturas enable row level security;
alter table public.saas_faturas enable row level security;
alter table public.saas_uso enable row level security;
alter table public.saas_eventos enable row level security;
alter table public.saas_leads enable row level security;
alter table public.saas_cupons enable row level security;
alter table public.saas_avisos enable row level security;
alter table public.saas_flags enable row level security;
alter table public.saas_auditoria_admin enable row level security;

-- perfis: dono lê/edita o seu; admin lê/edita todos (papel protegido por trigger)
create policy perfil_proprio_sel on public.saas_perfis for select to authenticated
  using (user_id = auth.uid() or public.saas_is_admin());
create policy perfil_proprio_upd on public.saas_perfis for update to authenticated
  using (user_id = auth.uid() or public.saas_is_admin());

-- planos ativos: leitura pública (página de preços)
create policy planos_publicos on public.saas_planos for select to anon, authenticated using (ativo = true or public.saas_is_admin());
create policy planos_admin_upd on public.saas_planos for update to authenticated using (public.saas_is_admin());
create policy planos_admin_ins on public.saas_planos for insert to authenticated with check (public.saas_is_admin());

-- assinaturas/faturas/uso: dono ou admin
create policy ass_sel on public.saas_assinaturas for select to authenticated using (user_id = auth.uid() or public.saas_is_admin());
create policy fat_sel on public.saas_faturas for select to authenticated using (user_id = auth.uid() or public.saas_is_admin());
create policy uso_sel on public.saas_uso for select to authenticated using (user_id = auth.uid() or public.saas_is_admin());

-- leads: qualquer visitante insere; só admin lê/atualiza
create policy leads_ins on public.saas_leads for insert to anon, authenticated with check (true);
create policy leads_sel on public.saas_leads for select to authenticated using (public.saas_is_admin());
create policy leads_upd on public.saas_leads for update to authenticated using (public.saas_is_admin());

-- eventos: escrita via RPC; leitura admin
create policy ev_sel on public.saas_eventos for select to authenticated using (public.saas_is_admin());

-- cupons/avisos/flags: leitura conforme uso; escrita admin
create policy cupom_admin on public.saas_cupons for all to authenticated using (public.saas_is_admin()) with check (public.saas_is_admin());
create policy avisos_sel on public.saas_avisos for select to anon, authenticated using (ativo = true or public.saas_is_admin());
create policy avisos_admin on public.saas_avisos for insert to authenticated with check (public.saas_is_admin());
create policy avisos_admin_upd on public.saas_avisos for update to authenticated using (public.saas_is_admin());
create policy flags_sel on public.saas_flags for select to anon, authenticated using (true);
create policy flags_admin on public.saas_flags for update to authenticated using (public.saas_is_admin());

-- auditoria: só admin lê; escrita apenas via funções security definer
create policy aud_sel on public.saas_auditoria_admin for select to authenticated using (public.saas_is_admin());

-- lista de clientes p/ admin: função (evita view SECURITY DEFINER exposta)
create or replace function public.saas_admin_clientes(p_busca text default null, p_limite int default 50)
returns table (user_id uuid, nome text, sobrenome text, email text, email_confirmado boolean,
               telefone text, papel text, criado_em timestamptz,
               plano_id text, assinatura_status text, ciclo text, trial_fim timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.saas_is_admin() then
    raise exception 'acesso restrito a administradores';
  end if;
  return query
  select p.user_id, p.nome, p.sobrenome, u.email::text, (u.email_confirmed_at is not null),
         p.telefone, p.papel, p.criado_em,
         a.plano_id, a.status, a.ciclo, a.trial_fim
  from public.saas_perfis p
  join auth.users u on u.id = p.user_id
  left join lateral (select * from public.saas_assinaturas a2 where a2.user_id = p.user_id order by a2.criado_em desc limit 1) a on true
  where p_busca is null or u.email ilike '%'||p_busca||'%' or p.nome ilike '%'||p_busca||'%' or p.sobrenome ilike '%'||p_busca||'%'
  order by p.criado_em desc limit least(coalesce(p_limite,50), 200);
end $$;
grant execute on function public.saas_admin_clientes(text, int) to authenticated;
