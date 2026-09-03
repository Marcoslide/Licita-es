alter table bolsa.contratos_gov add column if not exists execucao_coletada_em timestamptz;
create index if not exists cg_exec_idx on bolsa.contratos_gov (execucao_coletada_em) where execucao_coletada_em is null;
