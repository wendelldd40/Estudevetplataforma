-- Testa as permissões da v5 como cada tipo de pessoa. Rode num banco de teste
-- depois de base-supabase-antiga.sql e 10-plataforma-v5.sql. Falha com erro se algo vazar.
\set ON_ERROR_STOP 1
set client_min_messages = warning;
-- dados
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-00000000000a','admin@x.com'),('00000000-0000-0000-0000-00000000000b','ana@x.com'),('00000000-0000-0000-0000-00000000000c','bia@x.com');
insert into public.perfis (id, nome, email, papel) values
 ('00000000-0000-0000-0000-00000000000a','Admin','admin@x.com','admin'),('00000000-0000-0000-0000-00000000000b','Ana','ana@x.com','aluno');
insert into public.produtos (id, slug, nome, publicado, gratuito, preco_centavos) values
 ('10000000-0000-0000-0000-000000000001','pago','Pago',true,false,4700),('10000000-0000-0000-0000-000000000002','gratis','Grátis',true,true,0),('10000000-0000-0000-0000-000000000003','rascunho','Rascunho',false,false,100);
insert into public.modulos (id, produto_id, titulo, ordem) values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','M1',1),('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','M2',1);
insert into public.aulas (id, modulo_id, titulo, conteudo, ordem) values ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Aula paga','segredo',1),('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','Aula grátis','livre',1);
insert into public.materiais (aula_id, nome, arquivo_path) values ('30000000-0000-0000-0000-000000000001','planilha.xlsx','pago/planilha.xlsx');
insert into storage.objects (bucket_id, name) values ('materiais','pago/planilha.xlsx');
insert into public.encontros (id, titulo, data_hora, ativo) values ('40000000-0000-0000-0000-000000000001','Tira-dúvidas', now() + interval '3 days', true);
insert into public.encontro_salas (encontro_id, link) values ('40000000-0000-0000-0000-000000000001','https://meet/sala');
-- acesso pago guardado no e-mail da Bia, que ainda não tem perfil
insert into public.acessos (email, produto_id, origem) values ('bia@x.com','10000000-0000-0000-0000-000000000001','compra');

create or replace function pg_temp.como(sub text, email text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', sub, 'email', email)::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.checa(cond boolean, msg text) returns void language plpgsql as $$
begin if not cond then raise exception 'FALHOU: %', msg; end if; raise notice 'ok  %', msg; end $$;
set client_min_messages = notice;

-- ===== visitante (anon)
begin; set local role anon;
select pg_temp.checa((select count(*) from public.produtos) = 2, 'anon vê só produtos publicados');
select pg_temp.checa((select count(*) from public.aulas) = 1, 'anon só vê aula de produto grátis');
select pg_temp.checa((select count(*) from public.estrutura_publica('pago')) = 1, 'estrutura pública mostra títulos do pago');
select pg_temp.checa((select count(*) from public.estrutura_publica('rascunho')) = 0, 'estrutura pública esconde rascunho');
rollback;

-- ===== Ana, sem compra
begin; select pg_temp.como('00000000-0000-0000-0000-00000000000b','ana@x.com');
select pg_temp.checa((select count(*) from public.aulas where titulo = 'Aula paga') = 0, 'Ana não lê aula paga sem comprar');
select pg_temp.checa((select count(*) from public.materiais) = 0, 'Ana não lê material pago');
select pg_temp.checa((select count(*) from storage.objects) = 0, 'Ana não baixa arquivo pago');
select pg_temp.checa((select count(*) from public.produtos where slug='rascunho') = 0, 'Ana não vê rascunho');
select pg_temp.checa((select count(*) from public.acessos) = 0, 'Ana não vê acesso dos outros');
select pg_temp.checa((select count(*) from public.encontro_salas) = 0, 'Ana não vê link da sala sem se inscrever');
do $$ begin
  begin perform public.registrar_progresso('30000000-0000-0000-0000-000000000001', true, null); raise exception 'FALHOU: progresso em aula paga passou';
  exception when insufficient_privilege then raise notice 'ok  progresso em aula paga é recusado'; end;
  begin insert into public.acessos (user_id, email, produto_id, origem) values (auth.uid(), 'ana@x.com', '10000000-0000-0000-0000-000000000001', 'gratis'); raise exception 'FALHOU: liberou pago para si';
  exception when insufficient_privilege then raise notice 'ok  aluno não libera produto pago para si'; end;
  begin update public.perfis set papel = 'admin' where id = auth.uid(); raise exception 'FALHOU: virou admin';
  exception when insufficient_privilege then raise notice 'ok  aluno não vira admin'; end;
  begin perform public.admin_conceder_acesso('ana@x.com', '10000000-0000-0000-0000-000000000001', null); raise exception 'FALHOU: aluno concedeu acesso';
  exception when insufficient_privilege then raise notice 'ok  aluno não usa função de admin'; end;
  begin insert into public.registros_admin (acao) values ('forjado'); raise exception 'FALHOU: aluno escreveu no registro';
  exception when insufficient_privilege then raise notice 'ok  aluno não escreve no registro'; end;
end $$;
insert into public.acessos (user_id, email, produto_id, origem) values (auth.uid(), 'ana@x.com', '10000000-0000-0000-0000-000000000002', 'gratis');
select pg_temp.checa(true, 'aluno libera produto grátis para si');
select (public.registrar_progresso('30000000-0000-0000-0000-000000000002', true, 42)).concluida;
select pg_temp.checa((select posicao_seg from public.progresso where user_id = auth.uid()) = 42, 'progresso grava posição em aula liberada');
insert into public.encontro_inscricoes (encontro_id, user_id) values ('40000000-0000-0000-0000-000000000001', auth.uid());
select pg_temp.checa((select count(*) from public.encontro_salas) = 1, 'inscrita vê o link da sala');
commit;

-- ===== admin
begin; select pg_temp.como('00000000-0000-0000-0000-00000000000a','admin@x.com');
select pg_temp.checa((select count(*) from public.produtos) = 3, 'admin vê todos os produtos');
select id as acesso_ana from public.admin_conceder_acesso('ana@x.com', '10000000-0000-0000-0000-000000000001', 'teste') \gset
select pg_temp.checa((select count(*) from public.registros_admin where acao = 'acesso_concedido') = 1, 'concessão registrada');
update public.produtos set publicado = false where slug = 'pago';
update public.produtos set publicado = true where slug = 'pago';
select pg_temp.checa((select count(*) from public.registros_admin where acao like 'produto_%publicado') = 2, 'publicação registrada pelo gatilho');
select public.admin_duplicar_produto('10000000-0000-0000-0000-000000000001') as copia \gset
select pg_temp.checa((select count(*) from public.aulas a join public.modulos m on m.id = a.modulo_id where m.produto_id = :'copia') = 1, 'duplicar copia as aulas');
select pg_temp.checa((select publicado from public.produtos where id = :'copia') = false, 'cópia nasce rascunho');
commit;

begin; select pg_temp.como('00000000-0000-0000-0000-00000000000b','ana@x.com');
select pg_temp.checa((select count(*) from public.aulas where titulo = 'Aula paga') = 1, 'Ana lê aula paga depois da concessão');
select pg_temp.checa((select count(*) from storage.objects) = 1, 'Ana gera link do arquivo depois da concessão');
rollback;

begin; select pg_temp.como('00000000-0000-0000-0000-00000000000a','admin@x.com');
select public.admin_revogar_acesso(:'acesso_ana', 'reembolso');
commit;
begin; select pg_temp.como('00000000-0000-0000-0000-00000000000b','ana@x.com');
select pg_temp.checa((select count(*) from public.aulas where titulo = 'Aula paga') = 0, 'revogado: Ana perde a aula na hora');
select pg_temp.checa((select count(*) from public.acessos where revogado_em is not null) = 1, 'Ana ainda vê o histórico do acesso revogado');
rollback;

-- ===== Bia cria a conta e herda o acesso que estava no e-mail
insert into public.perfis (id, nome, email) values ('00000000-0000-0000-0000-00000000000c','Bia','bia@x.com');
begin; select pg_temp.como('00000000-0000-0000-0000-00000000000c','bia@x.com');
select pg_temp.checa((select count(*) from public.aulas where titulo = 'Aula paga') = 1, 'conta nova herda a compra feita antes do cadastro');
select pg_temp.checa((select user_id from public.acessos limit 1) = auth.uid(), 'acesso ligado ao id da conta nova');
rollback;

-- ===== CRM intacto
select pg_temp.checa((select count(*) from pg_policies where tablename = 'leads' and policyname = 'leads_qualquer') = 1, 'política do CRM não foi tocada');
\echo TUDO CERTO
