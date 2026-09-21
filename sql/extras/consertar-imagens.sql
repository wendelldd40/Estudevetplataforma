-- =====================================================================
--  EstudeVet · POR QUE AS IMAGENS NÃO SALVAM
--
--  Rode este arquivo inteiro no SQL Editor do Supabase.
--  Ele conserta e depois diz o que estava errado.
--
--  Motivo quase certo: a coluna capa_url e a tabela produto_fotos ainda
--  não existem no seu banco. O navegador reduz a imagem, manda para o
--  Supabase, o Supabase recusa, e até agora a plataforma engolia esse
--  erro em silêncio e ainda dizia "Produto salvo".
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. AS COLUNAS DA CAPA E DO LINK DA CAKTO
-- ---------------------------------------------------------------------
alter table public.produtos add column if not exists capa_url  text;
alter table public.produtos add column if not exists cakto_url text;


-- ---------------------------------------------------------------------
-- 2. A TABELA DAS FOTOS DE APLICAÇÃO
-- ---------------------------------------------------------------------
create table if not exists public.produto_fotos (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos(id) on delete cascade,
  url         text not null,
  legenda     text,
  ordem       int default 1,
  criado_em   timestamptz default now()
);

create index if not exists produto_fotos_idx on public.produto_fotos (produto_id, ordem);
alter table public.produto_fotos enable row level security;

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


-- ---------------------------------------------------------------------
-- 3. CONFIRMAR QUE VOCÊ É ADMIN
--    Sem isso a política acima barra a gravação e a foto não entra,
--    mesmo com a tabela existindo.
-- ---------------------------------------------------------------------
create or replace function public.emails_admin()
returns text[] language sql immutable as $$
  select array['wendelldd40@gmail.com']
$$;

insert into public.perfis (id, email, nome, papel, origem)
select u.id, u.email,
       coalesce(u.raw_user_meta_data ->> 'nome', split_part(u.email, '@', 1)),
       'admin', 'cadastro'
from   auth.users u
where  lower(u.email) = any (public.emails_admin())
  and  not exists (select 1 from public.perfis p where p.id = u.id);

update public.perfis
set    papel = 'admin'
where  lower(email) = any (public.emails_admin())
  and  papel is distinct from 'admin';


-- =====================================================================
--  DIAGNÓSTICO
--  Leia as três consultas. Elas dizem o que faltava.
-- =====================================================================

-- 1. As três peças existem agora?  Tudo tem que vir "ok".
select 'coluna capa_url' as peca,
       case when exists (select 1 from information_schema.columns
                         where table_schema='public' and table_name='produtos' and column_name='capa_url')
            then 'ok' else 'FALTANDO' end as estado
union all
select 'coluna cakto_url',
       case when exists (select 1 from information_schema.columns
                         where table_schema='public' and table_name='produtos' and column_name='cakto_url')
            then 'ok' else 'FALTANDO' end
union all
select 'tabela produto_fotos',
       case when exists (select 1 from information_schema.tables
                         where table_schema='public' and table_name='produto_fotos')
            then 'ok' else 'FALTANDO' end
union all
select 'sua conta e admin',
       case when exists (select 1 from public.perfis
                         where lower(email) = any (public.emails_admin()) and papel='admin')
            then 'ok' else 'FALTANDO, crie a conta pela tela de cadastro' end;

-- 2. Quantas capas e fotos já estão gravadas de verdade.
select p.nome,
       case when p.capa_url is null then 'sem capa'
            else 'capa de ' || pg_size_pretty(length(p.capa_url)::bigint) end as capa,
       count(f.id) as fotos
from   public.produtos p
left   join public.produto_fotos f on f.produto_id = p.id
group  by p.nome, p.capa_url
order  by p.nome;

-- 3. O tamanho total das imagens, para você acompanhar com o tempo.
--    A capa fica na própria linha do produto, então convém ficar de olho.
select pg_size_pretty(coalesce(sum(length(capa_url)),0)::bigint) as total_das_capas
from   public.produtos;
