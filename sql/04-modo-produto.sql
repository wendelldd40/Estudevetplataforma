-- =====================================================================
--  EstudeVet · DOIS TIPOS DE PRODUTO
--
--  Rode no SQL Editor. Pode rodar de novo sem estragar nada.
--
--  gateway  produto que se vende sozinho: tem preço, link da Cakto e
--           material entregue dentro da plataforma
--  vitrine  produto de conversa: aparece só na landing, com preço a
--           consultar e as fotos de aplicação
--
--  Tudo que já existe continua como gateway, que é o comportamento de hoje.
-- =====================================================================

alter table public.produtos add column if not exists modo text not null default 'gateway';

-- Só estes dois valores entram, para não aparecer um terceiro modo por engano.
alter table public.produtos drop constraint if exists produtos_modo_valido;
alter table public.produtos add  constraint produtos_modo_valido
  check (modo in ('gateway','vitrine'));

create index if not exists produtos_modo_idx on public.produtos (modo, publicado, ordem);

-- Produto de vitrine não cobra nada. Se algum já veio com preço ou link de
-- pagamento, isso é limpo aqui para não aparecer valor onde não deve.
update public.produtos
set    preco_centavos = 0,
       preco_de_centavos = null,
       cakto_url = null,
       assentos = 1,
       gratuito = false
where  modo = 'vitrine'
  and (preco_centavos <> 0 or preco_de_centavos is not null or cakto_url is not null);


-- =====================================================================
--  CONFERÊNCIA
-- =====================================================================

-- A coluna existe e só aceita os dois valores?
select column_name, data_type, column_default
from   information_schema.columns
where  table_schema='public' and table_name='produtos' and column_name='modo';

-- Como está dividido o seu catálogo hoje.
select modo,
       count(*)                          as total,
       count(*) filter (where publicado) as visiveis
from   public.produtos
group  by modo
order  by modo;

-- Produto de vitrine sem foto nenhuma. Ele fica fraco na landing,
-- porque é justamente das fotos que ele vive.
select p.nome, count(f.id) as fotos
from   public.produtos p
left   join public.produto_fotos f on f.produto_id = p.id
where  p.modo = 'vitrine' and p.publicado
group  by p.nome
having count(f.id) = 0;
