# INTEGRAÇÃO — Portal SaaS (landing, login e central administrativa)

Branch: `claude/landing-login-admin` · Data: 03/09/2026

Este documento explica o que foi entregue, como ativar e como integrar o portal
comercial ao restante da Bolsa de Licitações — **sem tocar** em `index.html`,
`src/bolsa_licitacoes/`, `deploy/vps/`, nas Edge Functions de coleta, no domínio
ou na VPS. Nenhum deploy foi feito; o site atual permanece intacto.

---

## 1. O que foi entregue

### 1.1 Banco (Supabase — projeto `rxcfbbzosbfiwyloqtdk`)

Migração **já aplicada** ao banco e versionada no repositório:

```
supabase/migrations/20260903T043000_saas_portal_auth_planos.sql
```

Convenção de nome: `YYYYMMDDTHHMMSS_descricao.sql` — nunca colide com as
migrações `0001..0008` da coleta nem com futuras (sempre use data/hora).

Tudo vive no schema `public` com prefixo `saas_` (a coleta continua isolada no
schema `bolsa`):

| Objeto | Papel |
|---|---|
| `saas_perfis` | Perfil do usuário (nome, telefone, `papel` cliente/admin, onboarding) |
| `saas_planos` | Planos 100% editáveis (preços, trial, destaque, `entitlements` jsonb) |
| `saas_assinaturas` | Assinatura com status rico (trial, ativa, inadimplente, cortesia, vitalícia…) |
| `saas_faturas`, `saas_uso` | Cobrança e consumo de limites |
| `saas_eventos` | Funil/telemetria (com UTM) |
| `saas_leads` | Leads do formulário da landing |
| `saas_cupons`, `saas_avisos`, `saas_flags` | Cupons, avisos sem deploy, feature flags |
| `saas_auditoria_admin` | Toda ação administrativa: quem, o quê, antes/depois, motivo |

Automação: trigger em `auth.users` cria perfil + assinatura `explorar/ativa` a
cada cadastro; trigger `saas_protege_papel` impede não-admin de se promover.

RPCs (SECURITY DEFINER, com gate `saas_is_admin()` onde cabível):
`saas_meu_acesso()`, `saas_registrar_evento()`, `saas_consumir()`,
`saas_is_admin()`, `saas_metricas_admin()`, `saas_admin_clientes()`,
`saas_admin_alterar_assinatura()`.

RLS ativa em todas as tabelas: cada usuário só lê a própria linha; leitura
pública apenas de planos ativos, flags e avisos; leads aceitam INSERT anônimo;
escrita administrativa exige `saas_is_admin()`.

### 1.2 Portal (`apps/portal/` — estático, sem framework, sem build)

| Página | Função |
|---|---|
| `index.html` | Landing completa (números **reais** da base, ao vivo; lead form; UTM) |
| `precos.html` | Planos carregados de `saas_planos` (fallback estático rotulado), toggle mensal/anual, comparativo |
| `cadastro.html` / `login.html` | Cadastro (Supabase Auth) e login com verificação de e-mail |
| `recuperar.html` / `redefinir.html` | Recuperação de senha ponta a ponta |
| `verificar-email.html` / `onboarding.html` | Reenvio de confirmação e onboarding |
| `app.html` | Área do assinante: plano/limites reais, números da base, gate de upgrade |
| `conta.html` | Dados, plano, faturas, troca de senha, sair de todos os dispositivos |
| `admin/index.html` | Central administrativa (ver §4) |
| `status.html` | Status público das fontes oficiais (ao vivo de `bolsa_vw_saude`) |
| `termos.html` / `privacidade.html` / `cookies.html` | Minutas legais (rotuladas como pendentes de revisão jurídica) |
| `assets/config.js` | Configuração por ambiente (URL/anon key/link do terminal) |
| `assets/portal.css` / `assets/portal.js` | Design system e núcleo (auth, UTM, tracking, gates) |

Teste executado: as 15 páginas renderizam sem erro de script inclusive
**offline** (fallbacks nunca quebram a página); páginas protegidas redirecionam
para o login.

---

## 2. Ativação do Auth (único passo manual obrigatório)

No painel Supabase → **Authentication**:

1. **URL Configuration → Site URL**: a URL onde o portal for servido
   (ex.: `https://seudominio.com.br/portal/`).
2. **Redirect URLs** — adicionar:
   - `<base>/login.html`
   - `<base>/redefinir.html`
3. **Email → Confirm email**: manter **ativado** (o fluxo já espera confirmação).
4. Opcional: personalizar os templates de e-mail (PT-BR) em Auth → Templates.

Enquanto o portal for testado localmente, adicione também
`http://localhost:<porta>/...` às Redirect URLs.

## 3. Como promover o primeiro admin

Crie sua conta normalmente pelo `cadastro.html`, confirme o e-mail e rode no SQL
Editor do Supabase:

```sql
update public.saas_perfis set papel = 'admin'
 where user_id = (select id from auth.users where email = 'seu@email.com');
```

A partir daí o link “Central administrativa” aparece no app e `admin/index.html`
libera. Demais admins podem ser promovidos do mesmo jeito (a trigger impede
autopromoção por RLS; só admin altera papel).

## 4. Central administrativa — o que já opera

- **Visão geral**: MRR, clientes (pagantes/gratuitos/trials/inadimplentes),
  leads e operação de dados real (licitações, atas, PCA, contratos, coletas 24h)
  — tudo via `saas_metricas_admin()`, nada fixo em código.
- **Clientes**: busca por nome/e-mail, plano/status de cada um, e alteração de
  assinatura com **motivo obrigatório** (gravado em `saas_auditoria_admin`).
- **Planos**: edição de preços/trial/destaque/ativo e dos `entitlements` (JSON)
  — vale imediatamente para a página de preços e para os gates.
- **Cupons**: criação e ativação/desativação.
- **Leads**: fila com origem/UTM e esteira de status (novo → convertido).
- **Fontes e coletas**: saúde real de cada fonte com últimas execuções.
- **Auditoria**: trilha completa das ações administrativas.

## 5. Como servir o portal sem tocar no site atual

O portal é 100% estático. Basta publicar a pasta `apps/portal/` em qualquer
caminho/subdomínio (ex.: `portal.seudominio.com.br` ou `/portal/`), sem build.
O site atual (`index.html` na raiz) não é alterado nem substituído.

Por ambiente, ajuste apenas `apps/portal/assets/config.js`:

- `SUPABASE_URL` / `SUPABASE_ANON_KEY` — a anon key é publicável por design; a
  segurança real está nas políticas RLS.
- `LINK_TERMINAL` — para onde aponta “Abrir o Terminal” (hoje `../../index.html`;
  em produção, a URL do terminal).
- `AMBIENTE` — `development` | `staging` | `production`.

## 6. Pagamentos (2ª entrega, por decisão de escopo)

Nada de gateway foi acoplado. A estrutura já está pronta para receber um
`PaymentProvider` desacoplado: `saas_assinaturas.gateway` (default `manual`),
`saas_faturas.gateway/gateway_ref` e os status ricos cobrem o ciclo completo.
Na fase atual, contratação/cancelamento pago é concluído pelo time (o portal já
comunica isso com transparência). Quando o gateway for escolhido
(Stripe/Pagar.me/Asaas…), entra como Edge Function + webhook sem retrabalho no
modelo de dados.

## 7. Segurança — resumo do modelo

- Anon key no front + RLS em todas as tabelas `saas_*` (nenhum dado de terceiro
  vaza mesmo com a key pública).
- Funções administrativas são SECURITY DEFINER **com gate interno**
  `saas_is_admin()` — não existem views privilegiadas expostas.
- Trigger bloqueia escalada de privilégio via update de `papel`.
- Login não revela se um e-mail existe (anti-enumeração) e o `?next=` só aceita
  caminho interno (anti open-redirect).
- Segredos (service role, SMTP, gateway) nunca entram no front — apenas a anon key.

## 8. O que NÃO foi alterado

`index.html` (terminal), `src/bolsa_licitacoes/`, `deploy/vps/`, as Edge
Functions de coleta (`coleta-*`), crons, o schema `bolsa`, o domínio e a VPS.
Nenhum deploy foi realizado.
