-- =====================================================================
-- 08-pix.sql  Pix dentro da vitrine (Cakto)
-- Rode uma vez no SQL Editor do Supabase (mesmo projeto do CRM).
-- =====================================================================
-- O que esta tabela guarda: número do pedido da Cakto, produto, valor, situação,
-- o id do lead que já existe no CRM e um resumo irreversível do IP (para limitar
-- abuso). NÃO guarda nome, e-mail, telefone nem CPF: isso fica na Cakto.
--
-- Ninguém de fora lê nem escreve. Só as funções cakto-pix e cakto-webhook,
-- que usam a service_role do lado do servidor.

create table if not exists public.pagamentos_pix (
  pedido_id      text primary key,           -- id do pedido na Cakto
  ref_id         text,                        -- código curto que aparece para o comprador
  produto        text not null,               -- orcamento, precificacao, pasta, kit-tres
  oferta         text not null,               -- id da oferta na Cakto
  valor          numeric(10,2),
  status         text not null default 'waiting_payment',
  lead_id        text,                        -- liga com public.leads.id, quando houver
  ip_hash        text,
  expira_em      timestamptz,
  criado_em      timestamptz not null default now(),
  verificado_em  timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  pago_em        timestamptz
);

create index if not exists pagamentos_pix_ip_idx     on public.pagamentos_pix (ip_hash, criado_em desc);
create index if not exists pagamentos_pix_status_idx on public.pagamentos_pix (status, criado_em desc);
create index if not exists pagamentos_pix_lead_idx   on public.pagamentos_pix (lead_id);

-- guarda o token da Cakto entre uma execução e outra da função
create table if not exists public.pix_config (
  chave  text primary key,
  valor  text not null,
  expira timestamptz
);

alter table public.pagamentos_pix enable row level security;
alter table public.pix_config     enable row level security;
-- sem nenhuma política: anon e authenticated não enxergam nada
revoke all on public.pagamentos_pix from anon, authenticated;
revoke all on public.pix_config     from anon, authenticated;

-- (opcional) para ver as vendas no Supabase, use o Table Editor, que entra como dono.
-- Uma consulta útil:
--   select ref_id, produto, valor, status, criado_em, pago_em
--   from public.pagamentos_pix order by criado_em desc limit 50;

notify pgrst, 'reload schema';
