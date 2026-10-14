-- =====================================================================
-- 10-plataforma-v5.sql   Plataforma EstudeVet v5
-- Rode uma vez no SQL Editor do Supabase (mesmo projeto de sempre).
-- Pode rodar de novo sem estragar nada: tudo é "se não existir".
-- =====================================================================
-- O que faz:
--   1. Acrescenta colunas novas às tabelas que já existem (nada é apagado).
--   2. Cria as tabelas novas: favoritos, avisos, encontro_salas, produto_ofertas,
--      pedido_eventos, pagamento_eventos, registros_admin.
--   3. Refaz as políticas de acesso (RLS) das tabelas da plataforma, com a regra
--      de permissão no banco: quem não tem o produto não lê aula nem material.
--   4. Cria as funções que a tela chama (progresso, conceder/revogar acesso...)
--      e os gatilhos que registram operações sensíveis.
--   5. Protege o bucket "materiais": só baixa quem tem acesso, por link temporário.
--
-- Não mexe em: leads, lead_eventos, tabelas crm_*, pagamentos_pix, pix_config.
-- Ids: o script compara ids como texto, então funciona com uuid ou text.
-- =====================================================================

-- ------------------------------------------------------------------ 1. colunas novas

alter table public.perfis    add column if not exists prefs jsonb not null default '{}'::jsonb;

alter table public.produtos  add column if not exists categoria text;
alter table public.produtos  add column if not exists arquivado boolean not null default false;
alter table public.produtos  add column if not exists atualizado_em timestamptz default now();

alter table public.aulas     add column if not exists criado_em timestamptz default now();

alter table public.materiais add column if not exists produto_id uuid;
alter table public.materiais add column if not exists tipo text not null default 'arquivo';
alter table public.materiais add column if not exists url text;
alter table public.materiais add column if not exists criado_em timestamptz default now();
do $$ begin
  alter table public.materiais alter column aula_id drop not null;
exception when others then null; end $$;

alter table public.progresso add column if not exists posicao_seg integer;
alter table public.progresso add column if not exists atualizado_em timestamptz default now();
alter table public.progresso add column if not exists concluida_em timestamptz;

alter table public.acessos   add column if not exists revogado_em timestamptz;
alter table public.acessos   add column if not exists motivo text;
alter table public.acessos   add column if not exists pedido_id uuid;

alter table public.pedidos   add column if not exists provedor text;
alter table public.pedidos   add column if not exists provedor_pedido_id text;
alter table public.pedidos   add column if not exists user_id uuid;
alter table public.pedidos   add column if not exists origem text;
alter table public.pedidos   add column if not exists atualizado_em timestamptz default now();

alter table public.posts     add column if not exists fixado boolean not null default false;

-- progresso: uma linha por pessoa por aula (a tela grava com upsert)
do $$ begin
  create unique index if not exists progresso_user_aula_uidx on public.progresso (user_id, aula_id);
exception when others then
  raise notice 'progresso tem linhas repetidas por pessoa e aula; o índice único não foi criado. Apague as repetidas e rode de novo.';
end $$;
create unique index if not exists pedidos_provedor_uidx on public.pedidos (provedor, provedor_pedido_id) where provedor_pedido_id is not null;
create index if not exists acessos_email_idx on public.acessos (lower(email));
create index if not exists acessos_produto_idx on public.acessos (produto_id);

-- ------------------------------------------------------------------ 2. tabelas novas

create table if not exists public.favoritos (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  tipo       text not null check (tipo in ('produto','material','aula')),
  ref_id     text not null,
  criado_em  timestamptz not null default now(),
  unique (user_id, tipo, ref_id)
);

create table if not exists public.avisos (
  id         uuid primary key default gen_random_uuid(),
  titulo     text not null,
  corpo      text,
  produto_id uuid,
  link       text,
  publicado  boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- o link da sala sai de encontros e mora aqui: só quem se inscreveu lê
create table if not exists public.encontro_salas (
  id          uuid primary key default gen_random_uuid(),
  encontro_id uuid not null unique,
  link        text not null
);

-- produto <-> oferta no meio de pagamento (é assim que o webhook sabe o que liberar)
create table if not exists public.produto_ofertas (
  id         uuid primary key default gen_random_uuid(),
  produto_id uuid not null,
  provedor   text not null check (provedor in ('cakto','asaas')),
  oferta_id  text not null,
  criado_em  timestamptz not null default now(),
  unique (provedor, oferta_id)
);

create table if not exists public.pedido_eventos (
  id         uuid primary key default gen_random_uuid(),
  pedido_id  uuid not null,
  status     text not null,
  evento     text,
  detalhe    jsonb,
  criado_em  timestamptz not null default now()
);
create index if not exists pedido_eventos_pedido_idx on public.pedido_eventos (pedido_id, criado_em);

-- cada aviso de pagamento recebido, uma vez só (idempotência)
create table if not exists public.pagamento_eventos (
  id          uuid primary key default gen_random_uuid(),
  provedor    text not null,
  chave       text not null,
  evento      text,
  pedido_id   uuid,
  resultado   text,
  recebido_em timestamptz not null default now(),
  unique (provedor, chave)
);

create table if not exists public.registros_admin (
  id         uuid primary key default gen_random_uuid(),
  ator_id    uuid,
  ator_email text,
  acao       text not null,
  alvo_tipo  text,
  alvo_id    text,
  detalhe    jsonb not null default '{}'::jsonb,
  criado_em  timestamptz not null default now()
);
create index if not exists registros_admin_quando_idx on public.registros_admin (criado_em desc);

-- copia o link das salas para a tabela protegida e limpa a coluna antiga
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='encontros' and column_name='link_sala') then
    insert into public.encontro_salas (encontro_id, link)
      select id, link_sala from public.encontros where coalesce(link_sala,'') <> ''
      on conflict (encontro_id) do nothing;
    update public.encontros set link_sala = null where link_sala is not null;
  end if;
end $$;

-- ------------------------------------------------------------------ 3. funções de apoio

create or replace function public.meu_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) $$;

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papel = 'admin')
$$;

-- tem acesso ao produto: admin, produto grátis publicado, ou acesso ativo pelo id ou pelo e-mail
create or replace function public.tem_acesso(p_produto text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_admin()
      or exists (select 1 from public.produtos p where p.id::text = p_produto and p.gratuito and p.publicado and not coalesce(p.arquivado,false))
      or exists (select 1 from public.acessos a
                 where a.produto_id::text = p_produto and a.revogado_em is null
                   and (a.user_id = auth.uid() or lower(a.email) = public.meu_email()))
$$;

create or replace function public.produto_da_aula(p_aula text) returns text
language sql stable security definer set search_path = public as $$
  select m.produto_id::text from public.aulas a join public.modulos m on m.id = a.modulo_id where a.id::text = p_aula
$$;

create or replace function public.registrar(p_acao text, p_alvo_tipo text, p_alvo_id text, p_detalhe jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.registros_admin (ator_id, ator_email, acao, alvo_tipo, alvo_id, detalhe)
  values (auth.uid(), coalesce(nullif(public.meu_email(),''), 'sistema'), p_acao, p_alvo_tipo, p_alvo_id, coalesce(p_detalhe,'{}'::jsonb))
$$;
revoke all on function public.registrar(text,text,text,jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------------ 4. RLS

-- liga RLS e apaga as políticas antigas só das tabelas da plataforma
do $$
declare t text; pol record;
begin
  foreach t in array array['perfis','produtos','modulos','aulas','materiais','progresso','acessos','favoritos','avisos',
    'encontros','encontro_salas','encontro_inscricoes','pedidos','pedido_itens','pedido_eventos','pagamento_eventos','produto_ofertas',
    'produto_bumps','produto_fotos','posts','respostas','certificados','licencas','licenca_membros','contatos','registros_admin']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table public.%I enable row level security', t);
      for pol in select policyname from pg_policies where schemaname='public' and tablename=t loop
        execute format('drop policy %I on public.%I', pol.policyname, t);
      end loop;
    end if;
  end loop;
end $$;

-- perfis
create policy perfis_le on public.perfis for select using (id = auth.uid() or public.eh_admin());
create policy perfis_cria on public.perfis for insert with check (id = auth.uid() or public.eh_admin());
create policy perfis_edita on public.perfis for update using (id = auth.uid() or public.eh_admin());
create policy perfis_admin_apaga on public.perfis for delete using (public.eh_admin());

-- produtos: catálogo publicado é público; rascunho só admin; o resto escreve só admin
create policy produtos_le on public.produtos for select
  using ((publicado and not coalesce(arquivado,false)) or public.tem_acesso(id::text) or public.eh_admin());
create policy produtos_admin on public.produtos for all using (public.eh_admin()) with check (public.eh_admin());

-- conteúdo: só quem tem o produto
create policy modulos_le on public.modulos for select using (public.tem_acesso(produto_id::text));
create policy modulos_admin on public.modulos for all using (public.eh_admin()) with check (public.eh_admin());
create policy aulas_le on public.aulas for select using (public.tem_acesso(public.produto_da_aula(id::text)));
create policy aulas_admin on public.aulas for all using (public.eh_admin()) with check (public.eh_admin());
create policy materiais_le on public.materiais for select
  using (public.tem_acesso(coalesce(produto_id::text, public.produto_da_aula(aula_id::text))));
create policy materiais_admin on public.materiais for all using (public.eh_admin()) with check (public.eh_admin());

-- progresso: cada um o seu, e só em aula liberada
create policy progresso_le on public.progresso for select using (user_id = auth.uid() or public.eh_admin());
create policy progresso_grava on public.progresso for insert
  with check (user_id = auth.uid() and public.tem_acesso(public.produto_da_aula(aula_id::text)));
create policy progresso_atualiza on public.progresso for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- acessos: cada um vê os seus; o aluno só libera para si produto grátis; o resto é admin (pelas funções)
create policy acessos_le on public.acessos for select
  using (user_id = auth.uid() or lower(email) = public.meu_email() or public.eh_admin());
create policy acessos_gratis on public.acessos for insert
  with check (user_id = auth.uid() and lower(email) = public.meu_email() and origem = 'gratis'
    and exists (select 1 from public.produtos p where p.id = produto_id and p.gratuito and p.publicado and not coalesce(p.arquivado,false)));
create policy acessos_admin on public.acessos for all using (public.eh_admin()) with check (public.eh_admin());

create policy favoritos_dono on public.favoritos for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy avisos_le on public.avisos for select
  using ((publicado and (produto_id is null or public.tem_acesso(produto_id::text))) or public.eh_admin());
create policy avisos_admin on public.avisos for all using (public.eh_admin()) with check (public.eh_admin());

create policy encontros_le on public.encontros for select
  using ((auth.uid() is not null and ativo and (produto_id is null or public.tem_acesso(produto_id::text))) or public.eh_admin());
create policy encontros_admin on public.encontros for all using (public.eh_admin()) with check (public.eh_admin());
create policy salas_le on public.encontro_salas for select
  using (public.eh_admin() or exists (select 1 from public.encontro_inscricoes i where i.encontro_id = encontro_salas.encontro_id and i.user_id = auth.uid()));
create policy salas_admin on public.encontro_salas for all using (public.eh_admin()) with check (public.eh_admin());
create policy inscricoes_le on public.encontro_inscricoes for select using (user_id = auth.uid() or public.eh_admin());
create policy inscricoes_cria on public.encontro_inscricoes for insert
  with check (user_id = auth.uid() and exists (select 1 from public.encontros e where e.id = encontro_id and e.ativo
    and (e.produto_id is null or public.tem_acesso(e.produto_id::text))));
create policy inscricoes_apaga on public.encontro_inscricoes for delete using (user_id = auth.uid() or public.eh_admin());

-- pedidos: o comprador vê os seus; quem grava é o webhook (chave de serviço, fora da RLS)
create policy pedidos_le on public.pedidos for select using (user_id = auth.uid() or lower(email) = public.meu_email() or public.eh_admin());
create policy pedidos_admin on public.pedidos for all using (public.eh_admin()) with check (public.eh_admin());
do $$ begin
  if to_regclass('public.pedido_itens') is not null then
    execute 'create policy pedido_itens_le on public.pedido_itens for select using (public.eh_admin() or exists (select 1 from public.pedidos p where p.id = pedido_id and (p.user_id = auth.uid() or lower(p.email) = public.meu_email())))';
    execute 'create policy pedido_itens_admin on public.pedido_itens for all using (public.eh_admin()) with check (public.eh_admin())';
  end if;
  if to_regclass('public.produto_bumps') is not null then
    execute 'create policy bumps_le on public.produto_bumps for select using (true)';
    execute 'create policy bumps_admin on public.produto_bumps for all using (public.eh_admin()) with check (public.eh_admin())';
  end if;
  if to_regclass('public.produto_fotos') is not null then
    execute 'create policy fotos_le on public.produto_fotos for select using (true)';
    execute 'create policy fotos_admin on public.produto_fotos for all using (public.eh_admin()) with check (public.eh_admin())';
  end if;
end $$;
create policy pedido_eventos_admin on public.pedido_eventos for select using (public.eh_admin());
create policy pagamento_eventos_admin on public.pagamento_eventos for select using (public.eh_admin());
create policy ofertas_admin on public.produto_ofertas for all using (public.eh_admin()) with check (public.eh_admin());
create policy registros_admin_le on public.registros_admin for select using (public.eh_admin());
-- registros_admin não tem política de escrita: só funções do banco gravam

-- comunidade
create policy posts_le on public.posts for select using (auth.uid() is not null);
create policy posts_cria on public.posts for insert with check (user_id = auth.uid());
create policy posts_edita on public.posts for update using (user_id = auth.uid() or public.eh_admin());
create policy posts_apaga on public.posts for delete using (user_id = auth.uid() or public.eh_admin());
create policy respostas_le on public.respostas for select using (auth.uid() is not null);
create policy respostas_cria on public.respostas for insert with check (user_id = auth.uid());
create policy respostas_apaga on public.respostas for delete using (user_id = auth.uid() or public.eh_admin());

-- certificados: emitidos pela função; validação pública também pela função
create policy certificados_le on public.certificados for select using (user_id = auth.uid() or public.eh_admin());
create policy certificados_admin on public.certificados for all using (public.eh_admin()) with check (public.eh_admin());

-- licenças de equipe
create policy licencas_le on public.licencas for select using (lower(titular_email) = public.meu_email() or titular_id = auth.uid() or public.eh_admin());
create policy licencas_admin on public.licencas for all using (public.eh_admin()) with check (public.eh_admin());
create policy membros_le on public.licenca_membros for select
  using (public.eh_admin() or exists (select 1 from public.licencas l where l.id = licenca_id and (lower(l.titular_email) = public.meu_email() or l.titular_id = auth.uid())));
create policy membros_admin on public.licenca_membros for all using (public.eh_admin()) with check (public.eh_admin());

-- fale comigo
create policy contatos_cria on public.contatos for insert with check (user_id = auth.uid());
create policy contatos_le on public.contatos for select using (user_id = auth.uid() or public.eh_admin());
create policy contatos_admin on public.contatos for update using (public.eh_admin()) with check (public.eh_admin());
create policy contatos_admin_apaga on public.contatos for delete using (public.eh_admin());

-- ------------------------------------------------------------------ 5. gatilhos

-- ninguém vira admin pela própria tela
create or replace function public.guarda_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.eh_admin() then
    if new.papel is distinct from old.papel then raise exception 'Sem permissão para mudar o papel.' using errcode = '42501'; end if;
    if new.email is distinct from old.email then raise exception 'O e-mail da conta não muda por aqui.' using errcode = '42501'; end if;
  end if;
  return new;
end $$;
drop trigger if exists guarda_perfil on public.perfis;
create trigger guarda_perfil before update on public.perfis for each row execute function public.guarda_perfil();

-- conta nova herda os acessos que já estavam no e-mail (compra antes do cadastro, liberação manual)
create or replace function public.liga_acessos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.acessos set user_id = new.id where user_id is null and lower(email) = lower(new.email);
  update public.pedidos set user_id = new.id where user_id is null and lower(email) = lower(new.email);
  return new;
end $$;
drop trigger if exists liga_acessos on public.perfis;
create trigger liga_acessos after insert on public.perfis for each row execute function public.liga_acessos();

-- publicação, arquivamento e exclusão de produto ficam no registro
create or replace function public.audita_produto() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    perform public.registrar('produto_excluido', 'produto', old.id::text, jsonb_build_object('produto', old.nome));
    return old;
  end if;
  if new.publicado is distinct from old.publicado then
    perform public.registrar(case when new.publicado then 'produto_publicado' else 'produto_despublicado' end, 'produto', new.id::text, jsonb_build_object('produto', new.nome));
  end if;
  if coalesce(new.arquivado,false) is distinct from coalesce(old.arquivado,false) then
    perform public.registrar(case when new.arquivado then 'produto_arquivado' else 'produto_restaurado' end, 'produto', new.id::text, jsonb_build_object('produto', new.nome));
  end if;
  return new;
end $$;
drop trigger if exists audita_produto on public.produtos;
create trigger audita_produto after update or delete on public.produtos for each row execute function public.audita_produto();

-- ------------------------------------------------------------------ 6. funções chamadas pela tela

-- progresso da aula: confere o acesso e grava posição e conclusão
create or replace function public.registrar_progresso(p_aula text, p_concluida boolean default null, p_posicao integer default null)
returns public.progresso language plpgsql security definer set search_path = public as $$
declare r public.progresso; v_aula uuid;
begin
  if auth.uid() is null then raise exception 'Entre na conta.' using errcode = '42501'; end if;
  if not public.tem_acesso(public.produto_da_aula(p_aula)) then raise exception 'Sem acesso a esta aula.' using errcode = '42501'; end if;
  select id into v_aula from public.aulas where id::text = p_aula;
  insert into public.progresso as g (user_id, aula_id, concluida, posicao_seg, atualizado_em, concluida_em)
  values (auth.uid(), v_aula, coalesce(p_concluida,false), p_posicao, now(), case when p_concluida then now() end)
  on conflict (user_id, aula_id) do update set
    concluida     = coalesce(p_concluida, g.concluida),
    concluida_em  = case when p_concluida is true and not g.concluida then now() when p_concluida is false then null else g.concluida_em end,
    posicao_seg   = coalesce(p_posicao, g.posicao_seg),
    atualizado_em = now()
  returning * into r;
  return r;
end $$;

-- o que tem dentro, para a página de venda (só títulos, nunca o conteúdo)
create or replace function public.estrutura_publica(p_slug text)
returns table (modulo_id text, modulo_titulo text, modulo_ordem integer, aula_titulo text, aula_ordem integer, duracao_min integer, tipo text)
language sql stable security definer set search_path = public as $$
  select m.id::text, m.titulo, m.ordem::int, a.titulo, a.ordem::int, a.duracao_min::int, a.tipo
  from public.produtos p join public.modulos m on m.produto_id = p.id join public.aulas a on a.modulo_id = m.id
  where p.slug = p_slug and p.publicado and not coalesce(p.arquivado,false)
  order by m.ordem, a.ordem
$$;

create or replace function public.admin_registrar(p_acao text, p_alvo_tipo text default null, p_alvo_id text default null, p_detalhe jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só o admin.' using errcode = '42501'; end if;
  perform public.registrar(p_acao, p_alvo_tipo, p_alvo_id, p_detalhe);
end $$;

create or replace function public.admin_conceder_acesso(p_email text, p_produto text, p_motivo text default null)
returns public.acessos language plpgsql security definer set search_path = public as $$
declare v_email text := lower(trim(p_email)); v_user uuid; v_prod record; r public.acessos;
begin
  if not public.eh_admin() then raise exception 'Só o admin.' using errcode = '42501'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;
  select id, nome into v_prod from public.produtos where id::text = p_produto;
  if v_prod.id is null then raise exception 'Produto não encontrado.'; end if;
  select id into v_user from public.perfis where lower(email) = v_email limit 1;
  select * into r from public.acessos where lower(email) = v_email and produto_id = v_prod.id order by revogado_em nulls first limit 1;
  if r.id is not null and r.revogado_em is null then raise exception 'Essa pessoa já tem esse produto.'; end if;
  if r.id is not null then
    update public.acessos set revogado_em = null, motivo = coalesce(p_motivo, motivo), user_id = coalesce(user_id, v_user) where id = r.id returning * into r;
  else
    insert into public.acessos (user_id, email, produto_id, origem, motivo) values (v_user, v_email, v_prod.id, 'manual', p_motivo) returning * into r;
  end if;
  perform public.registrar('acesso_concedido', 'acesso', r.id::text, jsonb_build_object('email', v_email, 'produto', v_prod.nome, 'motivo', p_motivo));
  return r;
end $$;

create or replace function public.admin_revogar_acesso(p_acesso text, p_motivo text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.eh_admin() then raise exception 'Só o admin.' using errcode = '42501'; end if;
  update public.acessos set revogado_em = now(), motivo = coalesce(p_motivo, motivo) where id::text = p_acesso and revogado_em is null returning * into r;
  if r.id is null then raise exception 'Acesso não encontrado ou já revogado.'; end if;
  perform public.registrar('acesso_revogado', 'acesso', p_acesso, jsonb_build_object('email', r.email, 'produto', (select nome from public.produtos where id = r.produto_id), 'motivo', p_motivo));
  return true;
end $$;

create or replace function public.admin_restaurar_acesso(p_acesso text)
returns boolean language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if not public.eh_admin() then raise exception 'Só o admin.' using errcode = '42501'; end if;
  update public.acessos set revogado_em = null where id::text = p_acesso returning * into r;
  if r.id is null then raise exception 'Acesso não encontrado.'; end if;
  perform public.registrar('acesso_restaurado', 'acesso', p_acesso, jsonb_build_object('email', r.email, 'produto', (select nome from public.produtos where id = r.produto_id)));
  return true;
end $$;

-- duplica produto com módulos, aulas e materiais (a cópia nasce rascunho)
create or replace function public.admin_duplicar_produto(p_produto text)
returns text language plpgsql security definer set search_path = public as $$
declare v_orig jsonb; v_novo uuid; m record; a record; v_mod uuid; v_aula uuid; v_sufixo text := substr(md5(random()::text), 1, 5);
begin
  if not public.eh_admin() then raise exception 'Só o admin.' using errcode = '42501'; end if;
  select to_jsonb(p) into v_orig from public.produtos p where p.id::text = p_produto;
  if v_orig is null then raise exception 'Produto não encontrado.'; end if;
  v_novo := gen_random_uuid();
  insert into public.produtos select (jsonb_populate_record(null::public.produtos, v_orig || jsonb_build_object(
    'id', v_novo, 'slug', (v_orig->>'slug') || '-copia-' || v_sufixo, 'nome', (v_orig->>'nome') || ' (cópia)',
    'publicado', false, 'arquivado', false, 'atualizado_em', now(), 'criado_em', now()))).*;
  for m in select * from public.modulos where produto_id::text = p_produto order by ordem loop
    v_mod := gen_random_uuid();
    insert into public.modulos select (jsonb_populate_record(null::public.modulos, to_jsonb(m) || jsonb_build_object('id', v_mod, 'produto_id', v_novo))).*;
    for a in select * from public.aulas where modulo_id = m.id order by ordem loop
      v_aula := gen_random_uuid();
      insert into public.aulas select (jsonb_populate_record(null::public.aulas, to_jsonb(a) || jsonb_build_object('id', v_aula, 'modulo_id', v_mod, 'criado_em', now()))).*;
      insert into public.materiais select (jsonb_populate_record(null::public.materiais, to_jsonb(x) || jsonb_build_object('id', gen_random_uuid(), 'aula_id', v_aula, 'criado_em', now()))).*
        from public.materiais x where x.aula_id = a.id;
    end loop;
  end loop;
  insert into public.materiais select (jsonb_populate_record(null::public.materiais, to_jsonb(x) || jsonb_build_object('id', gen_random_uuid(), 'produto_id', v_novo, 'criado_em', now()))).*
    from public.materiais x where x.produto_id::text = p_produto and x.aula_id is null;
  perform public.registrar('produto_duplicado', 'produto', v_novo::text, jsonb_build_object('origem', v_orig->>'nome'));
  return v_novo::text;
end $$;

-- certificado e licença: só cria se a versão anterior ainda não existir no banco
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'validar_certificado' and pronamespace = 'public'::regnamespace) then
    execute $f$
      create function public.validar_certificado(cod text)
      returns table (nome text, produto text, horas numeric, emitido_em timestamptz)
      language sql stable security definer set search_path = public as $q$
        select nome_snapshot, produto_snapshot, horas::numeric, emitido_em from public.certificados where upper(codigo) = upper(cod)
      $q$;
    $f$;
  end if;
  if not exists (select 1 from pg_proc where proname = 'emitir_certificado' and pronamespace = 'public'::regnamespace) then
    execute $f$
      create function public.emitir_certificado(pid uuid)
      returns public.certificados language plpgsql security definer set search_path = public as $q$
      declare c public.certificados; v_total int; v_feitas int; v_min int;
      begin
        if auth.uid() is null or not public.tem_acesso(pid::text) then raise exception 'Sem acesso.' using errcode = '42501'; end if;
        select * into c from public.certificados where user_id = auth.uid() and produto_id = pid;
        if c.id is not null then return c; end if;
        select count(*), coalesce(sum(a.duracao_min),0) into v_total, v_min from public.aulas a join public.modulos m on m.id = a.modulo_id where m.produto_id = pid;
        select count(*) into v_feitas from public.progresso g join public.aulas a on a.id = g.aula_id join public.modulos m on m.id = a.modulo_id
          where m.produto_id = pid and g.user_id = auth.uid() and g.concluida;
        if v_total = 0 or v_feitas < v_total then raise exception 'Conclua todas as aulas antes.'; end if;
        insert into public.certificados (codigo, user_id, produto_id, nome_snapshot, produto_snapshot, horas, emitido_em)
        values (upper(substr(md5(random()::text || clock_timestamp()::text), 1, 10)), auth.uid(), pid,
          (select coalesce(nome, email) from public.perfis where id = auth.uid()), (select nome from public.produtos where id = pid),
          greatest(1, round(v_min / 60.0, 1)), now())
        returning * into c;
        return c;
      end $q$;
    $f$;
  end if;
end $$;

grant execute on function public.registrar_progresso(text, boolean, integer) to authenticated;
grant execute on function public.estrutura_publica(text) to anon, authenticated;
grant execute on function public.tem_acesso(text) to anon, authenticated;
grant execute on function public.eh_admin() to anon, authenticated;
grant execute on function public.admin_registrar(text, text, text, jsonb) to authenticated;
grant execute on function public.admin_conceder_acesso(text, text, text) to authenticated;
grant execute on function public.admin_revogar_acesso(text, text) to authenticated;
grant execute on function public.admin_restaurar_acesso(text) to authenticated;
grant execute on function public.admin_duplicar_produto(text) to authenticated;

-- ------------------------------------------------------------------ 7. armazenamento

-- bucket privado: nada de link público permanente
insert into storage.buckets (id, name, public) values ('materiais', 'materiais', false)
  on conflict (id) do update set public = false;

do $$ declare pol record; begin
  for pol in select policyname from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'materiais_%' loop
    execute format('drop policy %I on storage.objects', pol.policyname);
  end loop;
end $$;

-- baixar (e gerar o link temporário) só quem tem acesso ao produto daquele arquivo
create policy materiais_le on storage.objects for select to authenticated using (
  bucket_id = 'materiais' and (
    public.eh_admin() or exists (
      select 1 from public.materiais m
      where m.arquivo_path = storage.objects.name
        and public.tem_acesso(coalesce(m.produto_id::text, public.produto_da_aula(m.aula_id::text))))));
create policy materiais_envia on storage.objects for insert to authenticated with check (bucket_id = 'materiais' and public.eh_admin());
create policy materiais_troca on storage.objects for update to authenticated using (bucket_id = 'materiais' and public.eh_admin());
create policy materiais_apaga on storage.objects for delete to authenticated using (bucket_id = 'materiais' and public.eh_admin());

notify pgrst, 'reload schema';

-- ------------------------------------------------------------------ conferência rápida (opcional)
-- select tablename, count(*) as politicas from pg_policies where schemaname='public' group by 1 order by 1;
-- select * from public.registros_admin order by criado_em desc limit 20;
