-- Simula o que já existe no Supabase antes da v5: o básico do Supabase (auth, storage, papéis)
-- e as tabelas da plataforma antiga. Só para teste local, NÃO rode no Supabase.
do $$ begin create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth; grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
grant execute on all functions in schema auth to anon, authenticated;
create schema storage; grant usage on schema storage to anon, authenticated;
create table storage.buckets (id text primary key, name text, public boolean default false);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
grant all on storage.objects, storage.buckets to anon, authenticated;

create table public.perfis (id uuid primary key references auth.users(id), nome text, email text not null, papel text not null default 'aluno', perfil_tipo text, whatsapp text, senha_provisoria boolean default false, criado_em timestamptz default now());
create table public.produtos (id uuid primary key default gen_random_uuid(), slug text unique not null, nome text not null, subtitulo text, descricao text, tipo text default 'curso', preco_centavos int default 0, preco_de_centavos int, gratuito boolean default false, emoji text, cor text, publicado boolean default false, ordem int default 0, modo text default 'gateway', bullets jsonb, capa_url text, cakto_url text, assentos int default 1, criado_em timestamptz default now());
create table public.modulos (id uuid primary key default gen_random_uuid(), produto_id uuid references public.produtos(id) on delete cascade, titulo text, ordem int default 0);
create table public.aulas (id uuid primary key default gen_random_uuid(), modulo_id uuid references public.modulos(id) on delete cascade, titulo text, descricao text, tipo text default 'texto', video_url text, conteudo text, duracao_min int, ordem int default 0);
create table public.materiais (id uuid primary key default gen_random_uuid(), aula_id uuid not null references public.aulas(id) on delete cascade, nome text, formato text, arquivo_path text, ordem int default 0);
create table public.progresso (id uuid primary key default gen_random_uuid(), user_id uuid, aula_id uuid references public.aulas(id) on delete cascade, concluida boolean default false, unique (user_id, aula_id));
create table public.acessos (id uuid primary key default gen_random_uuid(), user_id uuid, email text, produto_id uuid references public.produtos(id), origem text default 'compra', criado_em timestamptz default now());
create table public.pedidos (id uuid primary key default gen_random_uuid(), codigo text, nome text, email text, total_centavos int default 0, status text default 'pendente', metodo text, criado_em timestamptz default now());
create table public.encontros (id uuid primary key default gen_random_uuid(), titulo text, descricao text, data_hora timestamptz, duracao_min int default 60, vagas int default 30, produto_id uuid, link_sala text, ativo boolean default true);
create table public.encontro_inscricoes (id uuid primary key default gen_random_uuid(), encontro_id uuid references public.encontros(id) on delete cascade, user_id uuid);
create table public.posts (id uuid primary key default gen_random_uuid(), user_id uuid, autor_nome text, titulo text, corpo text, produto_id uuid, criado_em timestamptz default now());
create table public.respostas (id uuid primary key default gen_random_uuid(), post_id uuid references public.posts(id) on delete cascade, user_id uuid, autor_nome text, corpo text, criado_em timestamptz default now());
create table public.certificados (id uuid primary key default gen_random_uuid(), codigo text unique, user_id uuid, produto_id uuid, nome_snapshot text, produto_snapshot text, horas numeric, emitido_em timestamptz default now());
create table public.licencas (id uuid primary key default gen_random_uuid(), produto_id uuid, titular_email text, titular_id uuid, assentos int, criado_em timestamptz default now());
create table public.licenca_membros (id uuid primary key default gen_random_uuid(), licenca_id uuid references public.licencas(id) on delete cascade, email text, nome text, criado_em timestamptz default now());
create table public.contatos (id uuid primary key default gen_random_uuid(), user_id uuid, nome text, email text, whatsapp text, tipo text, contexto text, prazo text, status text default 'novo', criado_em timestamptz default now());
create table public.leads (id text primary key);  -- do CRM: a v5 não pode mexer
create policy leads_qualquer on public.leads for all using (true);
alter table public.leads enable row level security;
-- política antiga frouxa que a v5 precisa substituir
alter table public.aulas enable row level security;
create policy aulas_todos on public.aulas for select using (true);
