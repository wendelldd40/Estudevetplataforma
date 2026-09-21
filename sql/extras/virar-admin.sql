-- =====================================================================
--  EstudeVet · TORNAR wendelldd40@gmail.com ADMIN
--
--  Rode este arquivo inteiro no SQL Editor do Supabase.
--  Pode rodar quantas vezes quiser, não estraga nada.
--
--  Ele resolve os três casos possíveis:
--    A. A conta ainda não existe          -> ela já nasce admin quando você criar
--    B. A conta existe e tem perfil       -> o perfil vira admin agora
--    C. A conta existe e o perfil sumiu   -> o perfil é criado já como admin
--
--  O caso C acontece quando você criou a conta ANTES de rodar o schema,
--  porque aí o gatilho que cria o perfil ainda não existia. É o motivo
--  mais comum de "rodei o UPDATE e continuo sem ver o Admin".
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. A LISTA DE DONOS
--    Fonte da verdade. Para incluir mais alguém depois, acrescente o
--    e-mail no array e rode este arquivo de novo.
-- ---------------------------------------------------------------------
create or replace function public.emails_admin()
returns text[] language sql immutable as $$
  select array['wendelldd40@gmail.com']
$$;


-- ---------------------------------------------------------------------
-- 2. QUEM CRIAR CONTA DAQUI PARA FRENTE JÁ NASCE ADMIN SE ESTIVER NA LISTA
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- 3. CONTA QUE JÁ EXISTE NO AUTH MAS FICOU SEM PERFIL
--    Cria o perfil que faltava, já como admin.
-- ---------------------------------------------------------------------
insert into public.perfis (id, email, nome, papel, origem)
select u.id,
       u.email,
       coalesce(u.raw_user_meta_data ->> 'nome', split_part(u.email, '@', 1)),
       'admin',
       'cadastro'
from   auth.users u
where  lower(u.email) = any (public.emails_admin())
  and  not exists (select 1 from public.perfis p where p.id = u.id);


-- ---------------------------------------------------------------------
-- 4. PERFIL QUE JÁ EXISTE E AINDA ESTÁ COMO ALUNO
-- ---------------------------------------------------------------------
update public.perfis
set    papel = 'admin'
where  lower(email) = any (public.emails_admin())
  and  papel is distinct from 'admin';


-- =====================================================================
--  CONFERÊNCIA
--  Leia o resultado das duas consultas abaixo antes de sair da tela.
-- =====================================================================

-- 4.1  Diagnóstico em uma linha só.
select
  case
    when not exists (select 1 from auth.users where lower(email) = any (public.emails_admin()))
      then 'A conta ainda nao existe. Crie pela tela de cadastro da plataforma: ela ja vai nascer admin.'
    when exists (select 1 from public.perfis where lower(email) = any (public.emails_admin()) and papel = 'admin')
      then 'Pronto. A conta e admin. Saia e entre de novo na plataforma para o menu Admin aparecer.'
    else 'A conta existe mas nao ficou admin. Confira se o e-mail no Auth esta escrito igual ao da lista.'
  end as situacao;

-- 4.2  Quem é admin hoje, com o que veio do Auth ao lado.
select p.email,
       p.papel,
       p.nome,
       p.criado_em,
       (u.id is not null) as tem_conta_no_auth
from   public.perfis p
left   join auth.users u on u.id = p.id
where  p.papel = 'admin'
order  by p.criado_em;
