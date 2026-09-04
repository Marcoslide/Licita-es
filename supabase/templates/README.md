# Templates de e-mail — Bolsa de Licitações

Templates HTML para os e-mails transacionais de autenticação (Supabase Auth).
Nenhum destes arquivos contém segredo algum — são apenas HTML com as variáveis
oficiais do Supabase (`{{ .ConfirmationURL }}`, `{{ .Email }}` etc).

## Como aplicar

Estes templates **não são aplicados automaticamente** — o projeto ainda não usa
`supabase config push`/CLI para sincronizar Auth. Até lá, cole manualmente:

1. Acesse o projeto no Supabase Dashboard → **Authentication → Emails → Templates**.
2. Abra o template correspondente (tabela abaixo) e cole:
   - **Subject heading**: o assunto sugerido.
   - **Message body**: o conteúdo do arquivo `.html` correspondente (cole o HTML
     inteiro — os comentários `<!-- -->` no topo do arquivo são só documentação
     e podem ficar ou ser removidos, não afetam o e-mail).
3. Salve.

| Arquivo | Template no Supabase | Assunto sugerido |
|---|---|---|
| `confirmar-cadastro.html` | Confirm signup | Confirme seu e-mail — Bolsa de Licitações |
| `redefinir-senha.html` | Reset Password | Redefina sua senha — Bolsa de Licitações |
| `convite.html` | Invite user | Você foi convidado — Bolsa de Licitações |

## Pré-requisito

Estes templates só passam a valer para os e-mails realmente enviados **depois**
que o Custom SMTP (Resend) estiver ativo em Authentication → Emails → SMTP
Settings. Antes disso, o Supabase usa o serviço de e-mail embutido (baixo
limite, não confiável) e ignora a personalização de remetente/domínio — o
corpo do template continua valendo, mas o remetente será o padrão do Supabase.
Ver `supabase/migrations/20260903174613_autoconfirmar_email_sem_smtp.sql` para
o contexto do workaround temporário que hoje contorna esse serviço de e-mail
embutido — a remoção dele é assunto separado, tratado fora deste commit.

## Por que não há template de "Change email address"

O app ainda não tem o fluxo de troca de e-mail habilitado (o campo de e-mail em
`apps/portal/conta.html` está desabilitado). Quando esse fluxo existir, revisar
o template "Change Email Address" no mesmo painel.

## Design

- Layout de tabela (compatibilidade ampla com clientes de e-mail), CSS inline,
  sem imagens externas — prioriza entregabilidade.
- Cor de destaque (`#ffb020`) e marca "BL" seguem a identidade usada no portal
  (`apps/portal/assets/portal.css`), mas em fundo claro (mais seguro para
  e-mail transacional do que o tema escuro do produto).
- Responsivo: coluna única, largura máxima de 480px, botão com área de toque
  grande — testar no formato mobile do preview do Supabase antes de publicar.
