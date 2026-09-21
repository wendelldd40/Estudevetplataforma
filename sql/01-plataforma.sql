-- =====================================================================
--  PLATAFORMA DE PRODUTOS DIGITAIS , v2.0
--  Área do aluno + conteúdo dentro da plataforma + comunidade + agenda + admin
--  Rode este arquivo inteiro no SQL Editor do Supabase.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PERFIS  (1 linha por usuário do Auth)
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id                uuid primary key references auth.users(id) on delete cascade,
  nome              text not null default '',
  email             text not null,
  whatsapp          text,
  perfil_tipo       text,          -- veterinario_autonomo | gestor_clinica | outro
  papel             text not null default 'aluno',   -- aluno | admin
  senha_provisoria  boolean default false,           -- true = obriga trocar no 1º acesso
  consentimento     boolean default false,
  origem            text default 'cadastro',         -- cadastro | compra | manual
  criado_em         timestamptz default now(),
  ultimo_acesso     timestamptz
);

-- Donos da plataforma. Quem estiver aqui vira admin sozinho ao criar a conta,
-- então você não precisa lembrar de rodar UPDATE depois do cadastro.
create or replace function public.emails_admin()
returns text[] language sql immutable as $$
  select array['wendelldd40@gmail.com']
$$;

-- Cria o perfil sozinho quando um usuário nasce no Auth
create or replace function public.criar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfis (id, email, nome, whatsapp, perfil_tipo, papel, senha_provisoria, origem)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'nome', ''),
    new.raw_user_meta_data ->> 'whatsapp',
    new.raw_user_meta_data ->> 'perfil_tipo',
    case when lower(new.email) = any (public.emails_admin()) then 'admin' else 'aluno' end,
    coalesce((new.raw_user_meta_data ->> 'senha_provisoria')::boolean, false),
    coalesce(new.raw_user_meta_data ->> 'origem', 'cadastro')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.criar_perfil();

-- Quem é admin (usado por todas as políticas de escrita)
create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin')
$$;

-- ---------------------------------------------------------------------
-- 2. PRODUTOS → MÓDULOS → AULAS → MATERIAIS
-- ---------------------------------------------------------------------
create table if not exists public.produtos (
  id                uuid primary key default gen_random_uuid(),
  slug              text unique not null,
  nome              text not null,
  subtitulo         text,
  descricao         text,
  tipo              text default 'curso',      -- curso | kit | mentoria | workshop
  nicho             text default 'veterinaria',
  preco_centavos    int default 0,
  preco_de_centavos int,
  gratuito          boolean default false,
  emoji             text default '📦',
  cor               text default '#0f766e',
  bullets           jsonb default '[]'::jsonb,
  publicado         boolean default false,
  ordem             int default 100,
  criado_em         timestamptz default now()
);

create table if not exists public.modulos (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid references public.produtos(id) on delete cascade,
  titulo      text not null,
  ordem       int default 1
);

create table if not exists public.aulas (
  id          uuid primary key default gen_random_uuid(),
  modulo_id   uuid references public.modulos(id) on delete cascade,
  titulo      text not null,
  descricao   text,
  tipo        text default 'video',   -- video | texto
  video_url   text,                   -- YouTube/Vimeo (embed)
  conteudo    text,                   -- markdown simples da aula
  duracao_min int default 0,
  ordem       int default 1
);

-- Materiais anexos DA AULA (planilha, PDF, prompts) , nunca produto solto
create table if not exists public.materiais (
  id            uuid primary key default gen_random_uuid(),
  aula_id       uuid references public.aulas(id) on delete cascade,
  nome          text not null,
  formato       text,
  arquivo_path  text not null,        -- caminho no bucket privado "materiais"
  ordem         int default 1
);

create table if not exists public.progresso (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete cascade,
  aula_id       uuid references public.aulas(id) on delete cascade,
  concluida     boolean default true,
  atualizado_em timestamptz default now(),
  unique (user_id, aula_id)
);

-- Capa do produto e link de cobrança por produto (v3.5)
alter table public.produtos add column if not exists capa_url  text;
alter table public.produtos add column if not exists cakto_url text;

-- ---------------------------------------------------------------------
-- 3. ACESSOS  (quem pode abrir qual produto)
-- ---------------------------------------------------------------------
create table if not exists public.acessos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade,
  email       text not null,
  produto_id  uuid references public.produtos(id) on delete cascade,
  origem      text default 'compra',   -- compra | manual | gratis
  pedido_id   uuid,
  criado_em   timestamptz default now(),
  unique (email, produto_id)
);
create index if not exists acessos_email_idx on public.acessos (lower(email));

-- ---------------------------------------------------------------------
-- 4. VENDAS
-- ---------------------------------------------------------------------
create table if not exists public.pedidos (
  id                 uuid primary key default gen_random_uuid(),
  codigo             text unique not null default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  nome               text not null,
  email              text not null,
  whatsapp           text,
  total_centavos     int not null,
  status             text default 'pendente',   -- pendente | pago | estornado
  metodo             text,
  asaas_customer_id  text,
  asaas_payment_id   text,
  asaas_invoice_url  text,
  origem             text,
  criado_em          timestamptz default now(),
  pago_em            timestamptz
);

create table if not exists public.pedido_itens (
  id             uuid primary key default gen_random_uuid(),
  pedido_id      uuid references public.pedidos(id) on delete cascade,
  produto_id     uuid references public.produtos(id),
  nome_snapshot  text not null,
  preco_centavos int not null,
  is_bump        boolean default false
);

create table if not exists public.produto_bumps (
  produto_id      uuid references public.produtos(id) on delete cascade,
  bump_produto_id uuid references public.produtos(id) on delete cascade,
  headline        text,
  primary key (produto_id, bump_produto_id)
);

-- ---------------------------------------------------------------------
-- 5. AGENDA (encontros ao vivo)
-- ---------------------------------------------------------------------
create table if not exists public.encontros (
  id          uuid primary key default gen_random_uuid(),
  titulo      text not null,
  descricao   text,
  data_hora   timestamptz not null,
  duracao_min int default 90,
  vagas       int default 50,
  link_sala   text,                                   -- só para inscrito
  produto_id  uuid references public.produtos(id),    -- null = todos os alunos
  ativo       boolean default true,
  criado_em   timestamptz default now()
);

create table if not exists public.encontro_inscricoes (
  id          uuid primary key default gen_random_uuid(),
  encontro_id uuid references public.encontros(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  criado_em   timestamptz default now(),
  unique (encontro_id, user_id)
);

-- ---------------------------------------------------------------------
-- 6. COMUNIDADE
-- ---------------------------------------------------------------------
create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete cascade,
  autor_nome  text,
  titulo      text not null,
  corpo       text,
  produto_id  uuid references public.produtos(id),
  fixado      boolean default false,
  criado_em   timestamptz default now()
);

create table if not exists public.respostas (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid references public.posts(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete cascade,
  autor_nome  text,
  corpo       text not null,
  criado_em   timestamptz default now()
);

-- ---------------------------------------------------------------------
-- 6c. PEDIDOS DE SERVIÇO ("Fale comigo")
--     Aluno descreve o caso, o pedido cai aqui e a conversa segue no WhatsApp.
--     Não guarda nada de paciente: só o contexto do negócio de quem pediu.
-- ---------------------------------------------------------------------
create table if not exists public.contatos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  nome        text not null,
  email       text,
  whatsapp    text,
  tipo        text,
  contexto    text,
  prazo       text,
  status      text default 'novo',   -- novo | encerrado
  criado_em   timestamptz default now()
);

create index if not exists contatos_status_idx on public.contatos (status, criado_em desc);

-- ---------------------------------------------------------------------
-- 6b. LICENÇAS POR CLÍNICA (assentos para a equipe)
--     Quem compra é o dono; quem usa é a recepção. Uma licença dá N assentos.
-- ---------------------------------------------------------------------
alter table public.produtos add column if not exists assentos int default 1;

-- Integração com provedor de pagamento externo (Cakto)
alter table public.produtos add column if not exists cakto_offer_id text;
alter table public.pedidos  add column if not exists provedor text default 'asaas';
alter table public.pedidos  add column if not exists ref_externo text;
alter table public.pedidos  add column if not exists checkout_url text;
create index if not exists pedidos_ref_externo_idx on public.pedidos (ref_externo);

create table if not exists public.licencas (
  id            uuid primary key default gen_random_uuid(),
  produto_id    uuid references public.produtos(id) on delete cascade,
  titular_email text not null,
  titular_id    uuid references auth.users(id) on delete set null,
  assentos      int not null default 1,
  pedido_id     uuid,
  criado_em     timestamptz default now(),
  unique (titular_email, produto_id)
);
create index if not exists licencas_titular_idx on public.licencas (lower(titular_email));

create table if not exists public.licenca_membros (
  id         uuid primary key default gen_random_uuid(),
  licenca_id uuid references public.licencas(id) on delete cascade,
  email      text not null,
  nome       text,
  criado_em  timestamptz default now(),
  unique (licenca_id, email)
);

-- Quando a pessoa finalmente cria a conta, os acessos que estavam
-- esperando pelo e-mail dela (compra ou convite de equipe) se vinculam sozinhos.
create or replace function public.vincular_acessos()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.acessos set user_id = new.id
   where user_id is null and lower(email) = lower(new.email);
  update public.licencas set titular_id = new.id
   where titular_id is null and lower(titular_email) = lower(new.email);
  return new;
end $$;

drop trigger if exists on_perfil_criado on public.perfis;
create trigger on_perfil_criado
  after insert on public.perfis
  for each row execute function public.vincular_acessos();

-- Titular adiciona um funcionário: confere a titularidade e a vaga no servidor.
create or replace function public.adicionar_membro(p_licenca uuid, p_email text, p_nome text default null)
returns public.licenca_membros
language plpgsql security definer set search_path = public as $$
declare lic public.licencas; usados int; novo public.licenca_membros; alvo text;
begin
  alvo := lower(trim(p_email));
  select * into lic from public.licencas where id = p_licenca;
  if lic is null then raise exception 'licenca inexistente'; end if;
  if lower(lic.titular_email) <> lower(coalesce(auth.jwt() ->> 'email','')) and not public.eh_admin() then
    raise exception 'so o titular pode gerenciar a equipe';
  end if;

  -- o titular ocupa 1 assento; o resto é da equipe
  select count(*) into usados from public.licenca_membros where licenca_id = p_licenca;
  if not exists (select 1 from public.licenca_membros where licenca_id = p_licenca and email = alvo)
     and usados >= lic.assentos - 1 then
    raise exception 'todos os assentos desta licenca estao ocupados';
  end if;

  insert into public.licenca_membros (licenca_id, email, nome)
  values (p_licenca, alvo, p_nome)
  on conflict (licenca_id, email) do update set nome = excluded.nome
  returning * into novo;

  -- o acesso já entra; se a pessoa ainda não tem conta, o trigger vincula no cadastro
  insert into public.acessos (user_id, email, produto_id, origem)
  values ((select id from auth.users where lower(email) = alvo limit 1), alvo, lic.produto_id, 'equipe')
  on conflict (email, produto_id) do nothing;

  return novo;
end $$;

create or replace function public.remover_membro(p_membro uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m public.licenca_membros; lic public.licencas;
begin
  select * into m from public.licenca_membros where id = p_membro;
  if m is null then return; end if;
  select * into lic from public.licencas where id = m.licenca_id;
  if lower(lic.titular_email) <> lower(coalesce(auth.jwt() ->> 'email','')) and not public.eh_admin() then
    raise exception 'so o titular pode gerenciar a equipe';
  end if;
  delete from public.acessos where lower(email) = lower(m.email) and produto_id = lic.produto_id and origem = 'equipe';
  delete from public.licenca_membros where id = p_membro;
end $$;

grant execute on function public.adicionar_membro(uuid, text, text) to authenticated;
grant execute on function public.remover_membro(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 7. CERTIFICADOS
-- ---------------------------------------------------------------------
create table if not exists public.certificados (
  id             uuid primary key default gen_random_uuid(),
  codigo         text unique not null default upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),
  user_id        uuid references auth.users(id) on delete cascade,
  produto_id     uuid references public.produtos(id) on delete cascade,
  nome_snapshot  text not null,
  produto_snapshot text not null,
  horas          numeric(4,1) not null default 1,
  emitido_em     timestamptz default now(),
  unique (user_id, produto_id)
);

-- Emissão: só sai se o aluno tiver acesso E tiver concluído todas as aulas.
create or replace function public.emitir_certificado(pid uuid)
returns public.certificados
language plpgsql security definer set search_path = public as $$
declare
  total int; feitas int; minutos int; cert public.certificados; nome_aluno text; nome_prod text;
begin
  if not public.tem_acesso(pid) then raise exception 'sem acesso a este produto'; end if;

  select count(*), coalesce(sum(a.duracao_min),0) into total, minutos
  from public.aulas a join public.modulos m on m.id = a.modulo_id
  where m.produto_id = pid;

  select count(*) into feitas
  from public.progresso g
  join public.aulas a on a.id = g.aula_id
  join public.modulos m on m.id = a.modulo_id
  where m.produto_id = pid and g.user_id = auth.uid() and g.concluida;

  if total = 0 or feitas < total then raise exception 'produto ainda nao concluido'; end if;

  select nome into nome_aluno from public.perfis where id = auth.uid();
  select nome into nome_prod from public.produtos where id = pid;

  insert into public.certificados (user_id, produto_id, nome_snapshot, produto_snapshot, horas)
  values (auth.uid(), pid, coalesce(nome_aluno,''), nome_prod, greatest(round(minutos/60.0,1),1))
  on conflict (user_id, produto_id) do update set emitido_em = public.certificados.emitido_em
  returning * into cert;

  return cert;
end $$;

-- Validação pública por código (não expõe a tabela inteira)
create or replace function public.validar_certificado(cod text)
returns table (nome text, produto text, horas numeric, emitido_em timestamptz)
language sql security definer set search_path = public as $$
  select nome_snapshot, produto_snapshot, horas, emitido_em
  from public.certificados where upper(codigo) = upper(cod)
$$;
grant execute on function public.validar_certificado(text) to anon, authenticated;

-- =====================================================================
--  RLS
-- =====================================================================
alter table public.perfis              enable row level security;
alter table public.produtos            enable row level security;
alter table public.modulos             enable row level security;
alter table public.aulas               enable row level security;
alter table public.materiais           enable row level security;
alter table public.progresso           enable row level security;
alter table public.acessos             enable row level security;
alter table public.pedidos             enable row level security;
alter table public.pedido_itens        enable row level security;
alter table public.produto_bumps       enable row level security;
alter table public.encontros           enable row level security;
alter table public.encontro_inscricoes enable row level security;
alter table public.posts               enable row level security;
alter table public.respostas           enable row level security;
alter table public.contatos            enable row level security;
alter table public.certificados        enable row level security;
alter table public.licencas            enable row level security;
alter table public.licenca_membros     enable row level security;

-- LICENÇAS ----------------------------------------------------------
drop policy if exists "minha licenca" on public.licencas;
create policy "minha licenca" on public.licencas
  for select using (
    titular_id = auth.uid()
    or lower(titular_email) = lower(coalesce(auth.jwt() ->> 'email',''))
    or public.eh_admin());
drop policy if exists "admin gerencia licencas" on public.licencas;
create policy "admin gerencia licencas" on public.licencas
  for all using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "membros da minha licenca" on public.licenca_membros;
create policy "membros da minha licenca" on public.licenca_membros
  for select using (exists (
    select 1 from public.licencas l where l.id = licenca_membros.licenca_id
      and (l.titular_id = auth.uid()
        or lower(l.titular_email) = lower(coalesce(auth.jwt() ->> 'email',''))
        or public.eh_admin())));

-- CERTIFICADOS ------------------------------------------------------
drop policy if exists "meus certificados" on public.certificados;
create policy "meus certificados" on public.certificados
  for select using (user_id = auth.uid() or public.eh_admin());

-- PERFIS ------------------------------------------------------------
drop policy if exists "perfil proprio" on public.perfis;
create policy "perfil proprio" on public.perfis
  for select using (id = auth.uid() or public.eh_admin());
drop policy if exists "edito meu perfil" on public.perfis;
create policy "edito meu perfil" on public.perfis
  for update using (id = auth.uid() or public.eh_admin());

-- PRODUTOS ----------------------------------------------------------
drop policy if exists "catalogo publicado" on public.produtos;
create policy "catalogo publicado" on public.produtos
  for select using (publicado = true or public.eh_admin());
drop policy if exists "admin gerencia produtos" on public.produtos;
create policy "admin gerencia produtos" on public.produtos
  for all using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "bumps publicos" on public.produto_bumps;
create policy "bumps publicos" on public.produto_bumps for select using (true);
drop policy if exists "admin gerencia bumps" on public.produto_bumps;
create policy "admin gerencia bumps" on public.produto_bumps
  for all using (public.eh_admin()) with check (public.eh_admin());

-- Helper: tenho acesso a este produto?
create or replace function public.tem_acesso(pid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.acessos a where a.produto_id = pid and a.user_id = auth.uid()
  ) or exists (
    select 1 from public.produtos p where p.id = pid and p.gratuito = true and auth.uid() is not null
  ) or public.eh_admin()
$$;

-- CONTEÚDO ----------------------------------------------------------
drop policy if exists "modulos de quem tem acesso" on public.modulos;
create policy "modulos de quem tem acesso" on public.modulos
  for select using (public.tem_acesso(produto_id));
drop policy if exists "admin gerencia modulos" on public.modulos;
create policy "admin gerencia modulos" on public.modulos
  for all using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "aulas de quem tem acesso" on public.aulas;
create policy "aulas de quem tem acesso" on public.aulas
  for select using (exists (
    select 1 from public.modulos m where m.id = aulas.modulo_id and public.tem_acesso(m.produto_id)));
drop policy if exists "admin gerencia aulas" on public.aulas;
create policy "admin gerencia aulas" on public.aulas
  for all using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "materiais de quem tem acesso" on public.materiais;
create policy "materiais de quem tem acesso" on public.materiais
  for select using (exists (
    select 1 from public.aulas a join public.modulos m on m.id = a.modulo_id
    where a.id = materiais.aula_id and public.tem_acesso(m.produto_id)));
drop policy if exists "admin gerencia materiais" on public.materiais;
create policy "admin gerencia materiais" on public.materiais
  for all using (public.eh_admin()) with check (public.eh_admin());

-- PROGRESSO ---------------------------------------------------------
drop policy if exists "meu progresso" on public.progresso;
create policy "meu progresso" on public.progresso
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ACESSOS -----------------------------------------------------------
drop policy if exists "meus acessos" on public.acessos;
create policy "meus acessos" on public.acessos
  for select using (user_id = auth.uid() or public.eh_admin());
drop policy if exists "admin libera acesso" on public.acessos;
create policy "admin libera acesso" on public.acessos
  for all using (public.eh_admin()) with check (public.eh_admin());

-- PEDIDOS -----------------------------------------------------------
drop policy if exists "meus pedidos" on public.pedidos;
create policy "meus pedidos" on public.pedidos
  for select using (lower(email) = lower(coalesce(auth.jwt() ->> 'email','')) or public.eh_admin());
drop policy if exists "meus itens" on public.pedido_itens;
create policy "meus itens" on public.pedido_itens
  for select using (exists (
    select 1 from public.pedidos p where p.id = pedido_itens.pedido_id
      and (lower(p.email) = lower(coalesce(auth.jwt() ->> 'email','')) or public.eh_admin())));

-- AGENDA ------------------------------------------------------------
drop policy if exists "encontros dos meus produtos" on public.encontros;
create policy "encontros dos meus produtos" on public.encontros
  for select using (
    ativo = true and (
      produto_id is null and auth.uid() is not null
      or public.tem_acesso(produto_id)
    )
  );
drop policy if exists "admin gerencia encontros" on public.encontros;
create policy "admin gerencia encontros" on public.encontros
  for all using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "minhas inscricoes" on public.encontro_inscricoes;
create policy "minhas inscricoes" on public.encontro_inscricoes
  for select using (user_id = auth.uid() or public.eh_admin());
drop policy if exists "me inscrevo" on public.encontro_inscricoes;
create policy "me inscrevo" on public.encontro_inscricoes
  for insert with check (user_id = auth.uid());
drop policy if exists "cancelo inscricao" on public.encontro_inscricoes;
create policy "cancelo inscricao" on public.encontro_inscricoes
  for delete using (user_id = auth.uid() or public.eh_admin());

-- COMUNIDADE --------------------------------------------------------
drop policy if exists "comunidade leitura" on public.posts;
create policy "comunidade leitura" on public.posts
  for select using (auth.uid() is not null);
drop policy if exists "posto na comunidade" on public.posts;
create policy "posto na comunidade" on public.posts
  for insert with check (user_id = auth.uid());
drop policy if exists "apago meu post" on public.posts;
create policy "apago meu post" on public.posts
  for delete using (user_id = auth.uid() or public.eh_admin());

drop policy if exists "respostas leitura" on public.respostas;
create policy "respostas leitura" on public.respostas
  for select using (auth.uid() is not null);
drop policy if exists "respondo" on public.respostas;
create policy "respondo" on public.respostas
  for insert with check (user_id = auth.uid());
drop policy if exists "apago minha resposta" on public.respostas;
create policy "apago minha resposta" on public.respostas
  for delete using (user_id = auth.uid() or public.eh_admin());

-- PEDIDOS DE SERVIÇO ------------------------------------------------
-- O aluno vê e cria só os pedidos dele. Quem responde é o admin.
drop policy if exists "meus pedidos de servico" on public.contatos;
create policy "meus pedidos de servico" on public.contatos
  for select using (user_id = auth.uid() or public.eh_admin());
drop policy if exists "peco um servico" on public.contatos;
create policy "peco um servico" on public.contatos
  for insert with check (user_id = auth.uid());
drop policy if exists "admin mexe no pedido" on public.contatos;
create policy "admin mexe no pedido" on public.contatos
  for update using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists "admin apaga pedido" on public.contatos;
create policy "admin apaga pedido" on public.contatos
  for delete using (public.eh_admin());

-- =====================================================================
--  STORAGE , bucket privado "materiais"
--  Crie em Storage > New bucket > "materiais" (private) e rode isto.
-- =====================================================================
drop policy if exists "material so de quem tem acesso" on storage.objects;
create policy "material so de quem tem acesso" on storage.objects
  for select using (
    bucket_id = 'materiais'
    and exists (
      select 1 from public.materiais mt
      join public.aulas a  on a.id = mt.aula_id
      join public.modulos m on m.id = a.modulo_id
      where mt.arquivo_path = storage.objects.name
        and public.tem_acesso(m.produto_id)
    )
  );

-- =====================================================================
--  SEED , produtos, módulos e aulas de exemplo
-- =====================================================================
insert into public.produtos (slug, nome, subtitulo, descricao, tipo, preco_centavos, preco_de_centavos, gratuito, emoji, cor, bullets, publicado, ordem) values
('planilha-precificacao','Planilha de Precificação de Serviços Veterinários',
 'Descubra quanto sobra de verdade em cada serviço da sua clínica',
 'Planilha pronta em Excel com quatro abas e um manual em PDF de 12 páginas. Você preenche o custo fixo uma vez e a planilha devolve o lucro real de cada serviço e o preço que fecha a sua meta.',
 'kit', 9700, 19700, false, '📊', '#292827',
 '["Planilha em Excel, quatro abas, pronta para usar","Manual em PDF de 12 páginas ensinando passo a passo","Calculadora de um serviço e tabela com 35 linhas","Rateio do custo fixo por atendimento, do jeito certo"]', true, 1),
('kit-prompts-vet','30 Prompts para a Rotina Vet',
 'Os pedidos prontos que resolvem comunicação, recepção, gestão e conteúdo',
 'PDF de 24 páginas com 30 prompts organizados em 6 blocos, mais o arquivo de texto para copiar e colar. Inclui a ficha da clínica e o bloco de voz que impedem o texto de sair com cara de robô.',
 'kit', 4700, 9700, false, '🧠', '#30a560',
 '["30 prompts prontos em 6 blocos de tarefa","Ficha da clínica que personaliza toda resposta","Bloco de voz que tira a cara de texto gerado","Arquivo .txt para copiar sem brigar com o PDF"]', true, 2),
('precificacao-autonomo','Precificação do Vet Autônomo',
 'Quanto cobrar por serviço e quanto cobrar pela distância',
 'A planilha de preço de quem atende em domicílio, plantão ou freela. Calcula o seu custo por hora ocupada e por quilômetro rodado, devolve a taxa de deslocamento de cada região que você atende e monta a sua tabela por zona. Com simulador de chamado e manual em PDF de 11 páginas.',
 'kit', 7700, 14700, false, '🚗', '#2f4f3f',
 '["Taxa de deslocamento calculada por zona","Tabela pronta: serviço na linha, zona na coluna","Simulador: aquele chamado compensa ou não","Mostra quanto a taxa cai se você agrupar atendimentos"]', true, 1),
('orcamento-30s','Orçamento em 30 Segundos',
 'Monte, envie e acompanhe os seus orçamentos sem parar o atendimento',
 'Aplicativo de arquivo único que roda offline. Cadastre os seus serviços uma vez e responda "quanto custa?" em trinta segundos, com texto pronto para o WhatsApp e PDF com o seu logo. Guarda o histórico e mostra a sua taxa de aceite. Acompanha manual em PDF de 8 páginas.',
 'kit', 4700, 9700, false, '🧾', '#c9822f',
 '["Orçamento pronto em trinta segundos","Texto para WhatsApp e PDF com o seu logo","Validade automática, que evita a conversa do preço antigo","Taxa de aceite: descubra qual faixa de preço fecha"]', true, 2),
('rota-do-dia','Rota do Dia',
 'Saiba se aquele chamado do outro lado da cidade vale a viagem',
 'Aplicativo de arquivo único que roda offline. Monta o seu dia por região, avisa quando o horário não fecha, mostra quanto o dia rende por hora ocupada e responde se o chamado avulso compensa, com o preço mínimo que fecha a sua meta. Acompanha manual em PDF de 8 páginas.',
 'kit', 6700, 12700, false, '🗺', '#1f6e3f',
 '["O dia montado por região, com o deslocamento","Alerta quando o horário não fecha","Vale a pena ir? com o preço mínimo do chamado","Confirmação da véspera com janela de horário"]', true, 3),
('agenda-de-retorno','Agenda de Retorno',
 'O aplicativo que lembra você de falar com o tutor na hora certa',
 'Aplicativo de arquivo único que roda offline no celular e no computador. Você anota o atendimento em trinta segundos e ele mostra todo dia quem precisa de mensagem, com o texto pronto e o nome do animal no lugar. Acompanha manual em PDF de 8 páginas.',
 'kit', 6700, 12700, false, '🔔', '#3d4541',
 '["Aplicativo de verdade, não é planilha","Roda offline, sem conta e sem mensalidade","Mensagens prontas com o nome do animal","Prazos e textos que você mesmo configura"]', true, 2),
('planilha-balanco','Balanço Mensal da Clínica',
 'Feche o mês em vinte minutos e saiba para onde o lucro foi',
 'A planilha mãe do fechamento mensal, com manual em PDF de 10 páginas. Faturamento, deduções, custo variável, custo fixo, lucro gerencial, ponto de equilíbrio e destinação do lucro, em uma tela só.',
 'kit', 3700, 6700, false, '📈', '#26874e',
 '["Fechamento do mês em uma tela","Ponto de equilíbrio e meta de faturamento calculados","Aba de 12 meses com gráfico do ano","Manual em PDF de 10 páginas ensinando a preencher"]', true, 3),
('prontuario-comunicacao','Prontuário e Comunicação com Tutor',
 'Menos tempo escrevendo, tutor entendendo mais',
 'Como organizar prontuário e transformar explicação técnica em mensagem que o tutor entende, com a biblioteca de 200 mensagens anexa.',
 'curso', 14700, 24700, false, '💬', '#3d4541',
 '["5 aulas + biblioteca de 200 mensagens","Modelos de anamnese e evolução","Bloco de segurança, LGPD e limites","Casos reais de pós-operatório e orçamento"]', true, 2),
('kit-marketing','Kit Marketing para Clínica',
 'Um mês de conteúdo pronto para a clínica',
 'Calendário editorial, 30 legendas e 10 roteiros de Reels, com aula de como adaptar tudo para a sua realidade.',
 'kit', 9700, 14700, false, '📣', '#c9822f',
 '["Calendário editorial de 30 dias","30 legendas e 10 roteiros","Modelos de resposta no direct","Aula de adaptação para a sua clínica"]', true, 3),
('kit-mensagens-gratis','Kit Grátis: 5 Mensagens Prontas para a Recepção',
 'As cinco respostas que a recepção mais precisa e mais erra',
 'Cinco mensagens prontas para copiar e usar hoje: preço no WhatsApp, confirmação da véspera, orçamento, atraso e retorno. Grátis para quem tem conta.',
 'kit', 0, null, true, '🎁', '#1f6e3f',
 '["5 mensagens prontas para copiar","O erro comum em cada situação","Funciona em clínica, autônomo e pet shop","Grátis, só precisa criar a conta"]', true, 0),
('80-mensagens-tutores','80 Mensagens Prontas para Tutores',
 'Da confirmação de consulta à conversa mais difícil',
 'Biblioteca com 80 mensagens em 12 situações: agendamento, vacina, cirurgia, internação, exames, orçamento, doença crônica, filhote, pet idoso, óbito, reclamação e datas. Copie, troque o nome do pet e envie.',
 'kit', 4700, 9700, false, '💬', '#30a560',
 '["80 mensagens em 12 situações","O quando usar de cada uma","Bloco de óbito e luto, que ninguém escreve","Feitas para WhatsApp, sem cara de robô"]', true, 2),
('scripts-recepcao','Scripts de Atendimento para Recepção Veterinária',
 'A recepção para de perder cliente sem ninguém perceber',
 '15 scripts prontos, o prompt que adapta tudo à sua clínica, o treino com IA e a ficha de avaliação. Acesso para até 3 pessoas da equipe.',
 'kit', 9700, 19700, false, '💬', '#292827',
 '["15 scripts, do WhatsApp ao óbito","Prompt que personaliza para a sua clínica","Treino com 6 personas de tutor difícil","Acesso para 3 pessoas, certificado para cada uma"]', true, 1),
('primeiros-passos','Primeiros Passos com IA na Rotina Vet',
 'Comece por aqui, é de graça',
 'Três aulas curtas mostrando os usos mais simples e seguros de IA no dia a dia da clínica. Serve de porta de entrada para a plataforma.',
 'curso', 0, null, true, '🎁', '#1f6e3f',
 '["3 aulas curtas","O que nunca colocar na ferramenta","10 prompts para começar hoje","Grátis para quem tem conta"]', true, 0)
on conflict (slug) do nothing;

update public.produtos set assentos = 3 where slug = 'scripts-recepcao';

-- Produtos que vieram do seed de exemplo e ainda não têm arquivo para entregar.
-- Ficam fora do ar até existir o material. Para publicar, troque para true.
update public.produtos set publicado = false
 where slug in ('prontuario-comunicacao','kit-marketing');

insert into public.produto_bumps (produto_id, bump_produto_id, headline)
select a.id, b.id, h.headline
from (values
  -- Regra: o bump é sempre mais barato que o produto principal.
  ('scripts-recepcao','80-mensagens-tutores','Leve também as 80 mensagens prontas para tutores'),
  ('scripts-recepcao','kit-prompts-vet','Leve os 30 prompts e gere os próximos scripts sozinho'),
  ('planilha-precificacao','planilha-balanco','Leve junto o Balanço Mensal e feche o mês inteiro, não só o preço'),
  ('kit-prompts-vet','planilha-balanco','Leve o Balanço Mensal, que produz os números do bloco C'),
  ('80-mensagens-tutores','planilha-balanco','Leve o Balanço Mensal e feche o mês em vinte minutos'),
  ('agenda-de-retorno','kit-prompts-vet','Leve os 30 prompts e escreva sozinho as próximas mensagens'),
  ('agenda-de-retorno','orcamento-30s','Leve o Orçamento em 30 Segundos e responda o preço na hora'),
  ('rota-do-dia','orcamento-30s','Leve o Orçamento em 30 Segundos e feche o chamado ainda no WhatsApp'),
  ('orcamento-30s','planilha-balanco','Leve o Balanço Mensal e veja se o mês inteiro fecha'),
  ('precificacao-autonomo','rota-do-dia','Leve a Rota do Dia e aplique a tabela por zona no seu dia a dia')
) as h(pai, filho, headline)
join public.produtos a on a.slug = h.pai
join public.produtos b on b.slug = h.filho
on conflict do nothing;

-- Módulos e aulas do produto gratuito e do carro-chefe
with p as (select id, slug from public.produtos where slug in ('primeiros-passos','planilha-precificacao','planilha-balanco','kit-prompts-vet','agenda-de-retorno','orcamento-30s','rota-do-dia','precificacao-autonomo'))
insert into public.modulos (produto_id, titulo, ordem)
select p.id, m.titulo, m.ordem from p
join (values
 ('primeiros-passos','Começando',1),
 ('planilha-precificacao','A planilha e o manual',1),
 ('planilha-balanco','A planilha e o manual',1),
 ('kit-prompts-vet','Os arquivos do kit',1),
 ('agenda-de-retorno','O aplicativo e o manual',1),
 ('orcamento-30s','O aplicativo e o manual',1),
 ('rota-do-dia','O aplicativo e o manual',1),
 ('precificacao-autonomo','A planilha e o manual',1)
) as m(slug, titulo, ordem) on m.slug = p.slug
on conflict do nothing;

insert into public.aulas (modulo_id, titulo, descricao, tipo, conteudo, duracao_min, ordem)
select mo.id, a.titulo, a.descricao, 'texto', a.conteudo, a.dur, a.ordem
from (values
 ('Começando','O que a IA resolve e o que não resolve','O mapa do que vale delegar','Delegue redação, organização e repetição. Nunca delegue decisão clínica.\n\nIsso não é excesso de cuidado. A ferramenta escreve com confiança mesmo quando está errada, e ela não responde por nada. Quem assina é você, com o seu registro.\n\nVALE DELEGAR\nReescrever uma explicação técnica para o tutor entender.\nMontar a mensagem de acompanhamento do dia seguinte.\nTransformar anotação solta em documento organizado.\nEscrever o anúncio de vaga e o roteiro de entrevista.\nLer os números do seu fechamento e apontar hipóteses.\n\nNÃO DELEGUE\nDecidir o que o animal tem.\nEscolher tratamento, dose ou protocolo.\nInterpretar exame para tomar decisão.\nOrientar o tutor sobre saúde sem passar por você.\n\nO TESTE DE TRINTA SEGUNDOS\nAntes de pedir qualquer coisa, pergunte: se essa resposta sair errada, quem paga? Se a resposta for o animal, não delegue. Se for o seu tempo, delegue à vontade e confira antes de usar.',7,1),
 ('Começando','O que nunca colocar na ferramenta','Dado de tutor, dado de paciente e LGPD','Nome do tutor, telefone, endereço, documento e identificação do paciente ficam fora. Sempre. Você está colando em um serviço de terceiro, e dado de cliente não é seu para distribuir.\n\nERRADO\n"A Dona Marlene trouxe o Thor, cachorro dela de 7 anos, o telefone dela é 79 9..."\n\nCERTO\n"Tutora trouxe cão macho de 7 anos."\n\nA resposta sai igual e o risco desaparece. Anonimizar não piora o resultado, porque o que a ferramenta precisa é do contexto, não da identidade.\n\nOS QUATRO ERROS QUE ESTRAGAM A RESPOSTA\nPedir tudo de uma vez. Uma tarefa por pedido.\nAceitar a primeira resposta. A primeira quase nunca é a boa.\nNão dizer o tamanho. Sem limite de linhas vem texto de site institucional.\nConfiar sem conferir. Número, prazo, valor e afirmação sobre saúde você confere antes de mandar.',8,2),
 ('Começando','O seu primeiro pedido bem feito','Os dois blocos que mudam tudo','Um pedido que funciona tem cinco peças: papel, contexto, tarefa, formato e restrição. As duas primeiras você escreve uma vez só, e são estes dois blocos.\n\nBLOCO 1: A FICHA DA SUA CLÍNICA\nNome da clínica, cidade e bairro, estrutura, público que atende, serviços principais, como vocês falam com o tutor, e coisas que a gente nunca faz.\n\nA última linha é a que mais melhora a resposta. Se a sua clínica nunca dá preço fechado de cirurgia sem avaliar, escreva isso. A ferramenta passa a respeitar o seu limite sem você precisar repetir em todo pedido.\n\nBLOCO 2: O BLOCO DE VOZ\nEscreva como uma pessoa falando, não escrevendo. Sem travessão. Nada de "não é X, é Y", trio de adjetivos ou "no mundo de hoje". Frases curtas. Sem estatística sem fonte. Sem emoji decorativo. Use sempre o nome do animal. Termine com um próximo passo concreto.\n\nBaixe o material desta aula. Ele traz os dois blocos prontos para copiar e três prompts para você usar hoje: traduzir termo técnico para o tutor, responder "quanto custa?" no direct, e revisar um texto para não parecer robô.\n\nComece pelo segundo. É a mensagem mais enviada da sua clínica.',10,3),
 ('O aplicativo e o manual','Baixe os arquivos e comece','Aplicativo em HTML e manual em PDF','Baixe os dois arquivos nos materiais desta aula.\n\nAbra o aplicativo com um duplo clique no computador, ou pelo navegador no celular. Leia as Partes 2 e 3 do manual antes de anotar o primeiro atendimento, e configure o seu nome na aba Ajustes.',6,1),
 ('Os arquivos do kit','Baixe os arquivos e comece','PDF do kit e arquivo de texto','Baixe os dois arquivos nos materiais desta aula.\n\nLeia as Partes 1 e 2 do PDF antes de rodar qualquer prompt, preencha a ficha da clínica e guarde os dois blocos numa nota do celular. Depois use o arquivo de texto para copiar sem brigar com o PDF.',6,1),
 ('A planilha e o manual','Baixe os arquivos e comece','Planilha em Excel e manual em PDF','Baixe os dois arquivos nos materiais desta aula. Abra o manual primeiro, na Parte 2, e levante os cinco números antes de preencher a planilha.',5,1)
) as a(modulo, titulo, descricao, conteudo, dur, ordem)
join public.modulos mo on mo.titulo = a.modulo
on conflict do nothing;

-- Materiais das duas ferramentas.
-- Suba os arquivos no bucket privado "materiais" nestes caminhos antes de publicar.
insert into public.materiais (aula_id, nome, formato, arquivo_path, ordem)
select au.id, mt.nome, mt.formato, mt.caminho, mt.ordem
from public.aulas au
join public.modulos mo on mo.id = au.modulo_id
join public.produtos pr on pr.id = mo.produto_id
join (values
 ('planilha-precificacao','Planilha de Precificação de Serviços','xlsx','planilha-precificacao/AprendeVet-Precificacao-de-Servicos-v1.0.xlsx',1),
 ('planilha-precificacao','Manual: como usar a planilha','pdf','planilha-precificacao/AprendeVet-Manual-Precificacao-v1.0.pdf',2),
 ('planilha-balanco','Planilha de Balanço Mensal','xlsx','planilha-balanco/AprendeVet-Balanco-Mensal-v1.0.xlsx',1),
 ('planilha-balanco','Manual: como usar a planilha','pdf','planilha-balanco/AprendeVet-Manual-Balanco-Mensal-v1.0.pdf',2),
 ('primeiros-passos','Comece Aqui: os dois blocos e os 3 prompts','pdf','primeiros-passos/AprendeVet-Comece-Aqui-v1.0.pdf',1),
 ('kit-prompts-vet','30 Prompts para a Rotina Vet','pdf','kit-prompts-vet/AprendeVet-30-Prompts-Rotina-Vet-v1.0.pdf',1),
 ('kit-prompts-vet','Prompts para copiar e colar','txt','kit-prompts-vet/AprendeVet-30-Prompts-copiar-e-colar.txt',2),
 ('agenda-de-retorno','Agenda de Retorno (aplicativo)','html','agenda-de-retorno/AprendeVet-Agenda-de-Retorno-v1.0.html',1),
 ('agenda-de-retorno','Manual: como usar o aplicativo','pdf','agenda-de-retorno/AprendeVet-Manual-Agenda-de-Retorno-v1.0.pdf',2),
 ('orcamento-30s','Orçamento em 30 Segundos (aplicativo)','html','orcamento-30s/AprendeVet-Orcamento-em-30-Segundos-v1.0.html',1),
 ('orcamento-30s','Manual: como usar o aplicativo','pdf','orcamento-30s/AprendeVet-Manual-Orcamento-30s-v1.0.pdf',2),
 ('rota-do-dia','Rota do Dia (aplicativo)','html','rota-do-dia/AprendeVet-Rota-do-Dia-v1.0.html',1),
 ('rota-do-dia','Manual: como usar o aplicativo','pdf','rota-do-dia/AprendeVet-Manual-Rota-do-Dia-v1.0.pdf',2),
 ('precificacao-autonomo','Precificação do Vet Autônomo','xlsx','precificacao-autonomo/AprendeVet-Precificacao-Vet-Autonomo-v1.0.xlsx',1),
 ('precificacao-autonomo','Manual: como usar a planilha','pdf','precificacao-autonomo/AprendeVet-Manual-Precificacao-Autonomo-v1.0.pdf',2)
) as mt(slug, nome, formato, caminho, ordem) on mt.slug = pr.slug
where au.titulo in ('Baixe os arquivos e comece','O seu primeiro pedido bem feito')
on conflict do nothing;

-- Encontro aberto a todos os alunos
insert into public.encontros (titulo, descricao, data_hora, duracao_min, vagas, produto_id, ativo)
values ('Workshop ao vivo: IA na Prática para Veterinários',
        'Duas horas aplicando IA em prontuário, comunicação com tutor e conteúdo. Turma pequena, com espaço para o seu caso real.',
        now() + interval '14 days', 120, 30, null, true)
on conflict do nothing;

-- =====================================================================
--  DEPOIS DE CRIAR SUA CONTA, VIRE ADMIN:
--  update public.perfis set papel = 'admin' where email = 'seu@email.com';
-- =====================================================================
