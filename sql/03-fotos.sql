-- =====================================================================
--  EstudeVet · GALERIA DE FOTOS DO PRODUTO
--
--  Rode no SQL Editor do projeto opuaaoccuzkbahuvwamf.
--  Pode rodar de novo sem estragar nada.
--
--  A capa continua em produtos.capa_url. Esta tabela guarda as fotos
--  extras que aparecem quando o visitante abre o produto no site.
--  Fica em tabela separada de propósito: assim a vitrine carrega leve e
--  as fotos só são buscadas quando alguém abre aquele produto.
-- =====================================================================

create table if not exists public.produto_fotos (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos(id) on delete cascade,
  url         text not null,     -- data URI reduzida, ou link se um dia usar bucket
  legenda     text,              -- "a aba de zonas preenchida", "o orçamento no WhatsApp"
  ordem       int default 1,
  criado_em   timestamptz default now()
);

create index if not exists produto_fotos_idx on public.produto_fotos (produto_id, ordem);

alter table public.produto_fotos enable row level security;

-- Visitante vê as fotos de produto publicado. Nada mais.
drop policy if exists "fotos de produto publicado" on public.produto_fotos;
create policy "fotos de produto publicado" on public.produto_fotos
  for select to anon, authenticated
  using (exists (
    select 1 from public.produtos p
    where p.id = produto_fotos.produto_id
      and (p.publicado = true or public.eh_admin())
  ));

drop policy if exists "admin gerencia fotos" on public.produto_fotos;
create policy "admin gerencia fotos" on public.produto_fotos
  for all using (public.eh_admin()) with check (public.eh_admin());


-- =====================================================================
--  CONFERÊNCIA
-- =====================================================================

-- A tabela existe com RLS ligado?
select tablename, rowsecurity
from   pg_tables
where  schemaname = 'public' and tablename = 'produto_fotos';

-- Quantas fotos cada produto publicado tem hoje.
select p.nome, count(f.id) as fotos
from   public.produtos p
left   join public.produto_fotos f on f.produto_id = p.id
where  p.publicado
group  by p.nome
order  by fotos desc, p.nome;
