-- =====================================================================
--  EstudeVet · LEADS E LINHA DO TEMPO
--
--  Rode no SQL Editor. Pode rodar de novo sem estragar nada.
--
--  leads         quem preencheu o portão da entrada do site
--  lead_eventos  o que essa pessoa fez depois: abriu um produto, pediu
--                orçamento, descreveu o caso
--
--  O CRM que você vai montar lê estas duas tabelas. Uma linha por pessoa,
--  e a conversa dela na linha do tempo, em vez de vários leads repetidos.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. LEADS
--    O id vem do navegador (crypto.randomUUID) e fica guardado no
--    aparelho da pessoa. É isso que permite ligar os eventos ao lead
--    sem dar permissão de leitura para visitante.
-- ---------------------------------------------------------------------
create table if not exists public.leads (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  whatsapp   text not null,
  email      text,
  perfil     text,          -- autônomo | gestor de clínica | recém-formado | outro
  origem     text,          -- lido do ?src= da URL
  status     text default 'novo',   -- novo | conversando | virou cliente | descartado
  anotacao   text,          -- espaço seu, o site nunca escreve aqui
  criado_em  timestamptz default now()
);

-- Colunas que podem faltar se você rodou a versão anterior deste arquivo.
alter table public.leads add column if not exists email    text;
alter table public.leads add column if not exists perfil   text;
alter table public.leads add column if not exists anotacao text;

create index if not exists leads_status_idx   on public.leads (status, criado_em desc);
create index if not exists leads_whatsapp_idx on public.leads (whatsapp);

alter table public.leads enable row level security;

drop policy if exists "visitante deixa recado" on public.leads;
drop policy if exists "visitante se apresenta" on public.leads;
create policy "visitante se apresenta" on public.leads
  for insert to anon, authenticated
  with check (
    length(coalesce(nome,'')) between 2 and 120
    and length(coalesce(whatsapp,'')) between 10 and 15
    and length(coalesce(email,'')) <= 160
    and status = 'novo'          -- ninguém entra já marcado como cliente
    and anotacao is null         -- a anotação é sua, não do formulário
  );

drop policy if exists "admin le os leads" on public.leads;
create policy "admin le os leads" on public.leads
  for select using (public.eh_admin());
drop policy if exists "admin mexe no lead" on public.leads;
create policy "admin mexe no lead" on public.leads
  for update using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists "admin apaga lead" on public.leads;
create policy "admin apaga lead" on public.leads
  for delete using (public.eh_admin());


-- ---------------------------------------------------------------------
-- 2. LINHA DO TEMPO DO LEAD
-- ---------------------------------------------------------------------
create table if not exists public.lead_eventos (
  id         uuid primary key default gen_random_uuid(),
  lead_id    uuid references public.leads(id) on delete cascade,
  tipo       text not null,   -- abriu_produto | pediu_orcamento | perguntou_produto | descreveu_caso
  detalhe    text,            -- nome do produto, ou o texto que a pessoa escreveu
  prazo      text,
  criado_em  timestamptz default now()
);

create index if not exists lead_eventos_idx on public.lead_eventos (lead_id, criado_em desc);

alter table public.lead_eventos enable row level security;

drop policy if exists "visitante registra o que fez" on public.lead_eventos;
create policy "visitante registra o que fez" on public.lead_eventos
  for insert to anon, authenticated
  with check (
    tipo in ('abriu_produto','perguntou_produto','pediu_orcamento','descreveu_caso')
    and length(coalesce(detalhe,'')) <= 4000
  );

drop policy if exists "admin le os eventos" on public.lead_eventos;
create policy "admin le os eventos" on public.lead_eventos
  for select using (public.eh_admin());
drop policy if exists "admin apaga evento" on public.lead_eventos;
create policy "admin apaga evento" on public.lead_eventos
  for delete using (public.eh_admin());


-- =====================================================================
--  CONFERÊNCIA
-- =====================================================================

-- As duas tabelas existem com RLS ligado?
select tablename, rowsecurity
from   pg_tables
where  schemaname='public' and tablename in ('leads','lead_eventos')
order  by tablename;

-- Os leads mais recentes, com o que cada um fez no site.
select l.nome, l.whatsapp, l.email, l.perfil, l.origem, l.status, l.criado_em,
       count(e.id) as acoes_no_site
from   public.leads l
left   join public.lead_eventos e on e.lead_id = l.id
group  by l.id
order  by l.criado_em desc
limit  50;

-- Quais produtos mais despertam interesse.
select detalhe as produto, count(*) as vezes
from   public.lead_eventos
where  tipo in ('abriu_produto','perguntou_produto','pediu_orcamento')
group  by detalhe
order  by vezes desc
limit  20;
