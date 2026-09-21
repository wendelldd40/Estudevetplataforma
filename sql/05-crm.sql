-- =====================================================================
--  CRM do Wendell · esquema
--
--  Rode inteiro no SQL Editor do mesmo projeto Supabase
--  (opuaaoccuzkbahuvwamf). Pode rodar de novo sem estragar nada.
--
--  Tudo aqui é privado: só quem está em public.emails_admin() enxerga.
--  O site público continua podendo apenas INSERIR em leads e lead_eventos,
--  como antes. O CRM é a outra ponta, que lê e organiza.
--
--  Depende de public.eh_admin(), que veio no schema da plataforma.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. NEGÓCIOS
--    Cada frente sua. O CRM é um só para todas, e o negócio é o que
--    separa o funil da EstudeVet do funil do ZeloVet.
-- ---------------------------------------------------------------------
create table if not exists public.crm_negocios (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  cor        text default '#30a560',
  ativo      boolean default true,
  ordem      int default 100,
  criado_em  timestamptz default now()
);


-- ---------------------------------------------------------------------
-- 2. ETIQUETAS
--    grupo serve para você filtrar por dimensão. Os grupos que já vêm:
--    nicho (o que a pessoa é), porte, temperatura e canal.
-- ---------------------------------------------------------------------
create table if not exists public.crm_tags (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  grupo      text default 'nicho',
  cor        text default '#565c58',
  ordem      int default 100,
  criado_em  timestamptz default now(),
  unique (grupo, nome)
);


-- ---------------------------------------------------------------------
-- 3. CONTATOS
--    Uma linha por pessoa, venha ela do site ou cadastrada na mão.
-- ---------------------------------------------------------------------
create table if not exists public.crm_contatos (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  whatsapp      text,
  email         text,
  empresa       text,
  cidade        text,
  negocio_id    uuid references public.crm_negocios(id) on delete set null,
  etapa         text not null default 'novo',
     -- novo | conversando | proposta | fechado | perdido
  valor_centavos int default 0,        -- quanto esse negócio vale se fechar
  origem        text,                  -- site, indicação, instagram, prospecção
  lead_id       uuid references public.leads(id) on delete set null,
  motivo_perda  text,
  anotacao      text,
  criado_em     timestamptz default now(),
  atualizado_em timestamptz default now()
);

create index if not exists crm_contatos_etapa_idx   on public.crm_contatos (etapa, atualizado_em desc);
create index if not exists crm_contatos_negocio_idx on public.crm_contatos (negocio_id);
create index if not exists crm_contatos_lead_idx    on public.crm_contatos (lead_id);
create index if not exists crm_contatos_busca_idx   on public.crm_contatos (lower(nome));

-- atualizado_em sozinho, para a lista ordenar por quem mexeu por último
create or replace function public.crm_toca()
returns trigger language plpgsql as $$
begin new.atualizado_em = now(); return new; end $$;

drop trigger if exists crm_contatos_toca on public.crm_contatos;
create trigger crm_contatos_toca before update on public.crm_contatos
  for each row execute function public.crm_toca();


create table if not exists public.crm_contato_tags (
  contato_id uuid references public.crm_contatos(id) on delete cascade,
  tag_id     uuid references public.crm_tags(id)     on delete cascade,
  primary key (contato_id, tag_id)
);


-- ---------------------------------------------------------------------
-- 4. INTERAÇÕES
--    A conversa. Entram as suas anotações e o que veio do site.
-- ---------------------------------------------------------------------
create table if not exists public.crm_interacoes (
  id         uuid primary key default gen_random_uuid(),
  contato_id uuid references public.crm_contatos(id) on delete cascade,
  tipo       text default 'nota',
     -- nota | whatsapp | ligacao | reuniao | site | etapa
  texto      text,
  criado_em  timestamptz default now()
);

create index if not exists crm_interacoes_idx on public.crm_interacoes (contato_id, criado_em desc);


-- ---------------------------------------------------------------------
-- 5. TAREFAS
--    O próximo passo com data. É o que impede o lead de esfriar.
-- ---------------------------------------------------------------------
create table if not exists public.crm_tarefas (
  id         uuid primary key default gen_random_uuid(),
  contato_id uuid references public.crm_contatos(id) on delete cascade,
  titulo     text not null,
  vence_em   date not null,
  feito      boolean default false,
  feito_em   timestamptz,
  criado_em  timestamptz default now()
);

create index if not exists crm_tarefas_idx on public.crm_tarefas (feito, vence_em);


-- ---------------------------------------------------------------------
-- 6. RECEITAS
--    O que entrou de verdade. Separado do valor previsto do contato,
--    porque previsão não é dinheiro.
-- ---------------------------------------------------------------------
create table if not exists public.crm_receitas (
  id             uuid primary key default gen_random_uuid(),
  contato_id     uuid references public.crm_contatos(id) on delete set null,
  negocio_id     uuid references public.crm_negocios(id) on delete set null,
  descricao      text not null,
  valor_centavos int not null,
  metodo         text,          -- pix | cartão | boleto | dinheiro | outro
  recebido_em    date not null default current_date,
  criado_em      timestamptz default now()
);

create index if not exists crm_receitas_idx on public.crm_receitas (recebido_em desc);


-- =====================================================================
--  RLS: tudo trancado, só admin entra
-- =====================================================================
alter table public.crm_negocios     enable row level security;
alter table public.crm_tags         enable row level security;
alter table public.crm_contatos     enable row level security;
alter table public.crm_contato_tags enable row level security;
alter table public.crm_interacoes   enable row level security;
alter table public.crm_tarefas      enable row level security;
alter table public.crm_receitas     enable row level security;

do $$
declare t text;
begin
  foreach t in array array['crm_negocios','crm_tags','crm_contatos',
                           'crm_contato_tags','crm_interacoes','crm_tarefas','crm_receitas']
  loop
    execute format('drop policy if exists "so admin" on public.%I', t);
    execute format('create policy "so admin" on public.%I for all
                      using (public.eh_admin()) with check (public.eh_admin())', t);
  end loop;
end $$;


-- =====================================================================
--  SEMENTE
--  Negócios e etiquetas iniciais. Mexa à vontade depois, pela tela
--  de Ajustes do CRM.
-- =====================================================================
insert into public.crm_negocios (nome, cor, ordem) values
  ('EstudeVet',     '#30a560', 1),
  ('ZeloVet',       '#1f6e3f', 2),
  ('Sob medida',    '#c9822f', 3),
  ('Outros',        '#3d4541', 9)
on conflict (nome) do nothing;

insert into public.crm_tags (nome, grupo, cor, ordem) values
  -- quem é a pessoa
  ('Veterinário autônomo',      'nicho', '#30a560', 1),
  ('Dono de clínica',           'nicho', '#26874e', 2),
  ('Gestor de clínica',         'nicho', '#1f6e3f', 3),
  ('Recém-formado',             'nicho', '#2f4f3f', 4),
  ('Estudante de veterinária',  'nicho', '#3d4541', 5),
  -- fora da veterinária, porque o CRM atende todas as suas frentes
  ('Pet shop',                  'nicho', '#c9822f', 10),
  ('Banho e tosa',              'nicho', '#a3641f', 11),
  ('Petiscaria ou loja pet',    'nicho', '#8a5a1d', 12),
  ('Outro comércio',            'nicho', '#565c58', 13),
  ('Prestador de serviço',      'nicho', '#3d4541', 14),
  -- tamanho
  ('Sozinho',                   'porte', '#565c58', 1),
  ('Até 3 pessoas',             'porte', '#565c58', 2),
  ('Equipe montada',            'porte', '#565c58', 3),
  -- quão quente está
  ('Quente',                    'temperatura', '#b4453a', 1),
  ('Morno',                     'temperatura', '#c9822f', 2),
  ('Frio',                      'temperatura', '#8a918c', 3),
  -- por onde chegou
  ('Site',                      'canal', '#30a560', 1),
  ('Instagram',                 'canal', '#a3641f', 2),
  ('Indicação',                 'canal', '#26874e', 3),
  ('Prospecção fria',           'canal', '#565c58', 4),
  ('Evento',                    'canal', '#3d4541', 5)
on conflict (grupo, nome) do nothing;


-- =====================================================================
--  CONFERÊNCIA
-- =====================================================================

select tablename, rowsecurity
from   pg_tables
where  schemaname='public' and tablename like 'crm_%'
order  by tablename;

select (select count(*) from public.crm_negocios) as negocios,
       (select count(*) from public.crm_tags)     as etiquetas,
       (select count(*) from public.leads)        as leads_do_site;
