-- Ajuste de higiene antes de nascer a 2ª fonte da mesma família de
-- tecnologia (BLL Compras, mesma plataforma da BNC): 'documento_bnc'
-- era um nome de entidade específico por fonte, o que contradiz o
-- próprio motor genérico (entidade = tipo da coisa; fonte_id já
-- distingue de onde veio). Renomeia para 'documento_processo' nas 3
-- tabelas do motor. Puramente um rename, sem perda de dado — só as
-- linhas da BNC gravadas hoje (id de teste, não afeta nada em produção
-- fora do próprio motor genérico ainda em prova).
update bolsa.estado_atual set entidade = 'documento_processo' where entidade = 'documento_bnc';
update bolsa.estado_versoes set entidade = 'documento_processo' where entidade = 'documento_bnc';
update bolsa.eventos set entidade = 'documento_processo' where entidade = 'documento_bnc';
