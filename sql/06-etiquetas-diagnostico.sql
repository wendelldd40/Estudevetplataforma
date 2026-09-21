-- =====================================================================
--  EstudeVet · etiquetas que o diagnóstico precisa
--
--  Rode no SQL Editor do projeto opuaaoccuzkbahuvwamf.
--  Pode rodar de novo sem estragar nada.
--
--  A página de diagnóstico grava o lead em public.leads com o campo
--  perfil preenchido. Quando você importa esse lead na tela Entrada do
--  CRM, ele procura uma etiqueta de nicho com o mesmo nome do perfil.
--  Duas das opções da página ainda não existiam como etiqueta.
-- =====================================================================

insert into public.crm_tags (nome, grupo, cor, ordem) values
  ('Consultor ou assessor', 'nicho', '#26874e', 6),
  ('Meta Ads',              'canal', '#c9822f', 6)
on conflict (grupo, nome) do nothing;


-- ---------------------------------------------------------------------
-- CONFERÊNCIA
-- ---------------------------------------------------------------------

-- As etiquetas de nicho precisam bater com as opções da página:
--   Veterinário autônomo | Consultor ou assessor | Dono de clínica
--   Recém-formado        | Prestador de serviço
select grupo, nome from public.crm_tags
where  grupo in ('nicho','canal')
order  by grupo, ordem;

-- Os diagnósticos que já chegaram, com a frente mais fraca de cada um.
select l.nome, l.whatsapp, l.perfil, l.origem, l.criado_em,
       e.prazo as faixa
from   public.leads l
join   public.lead_eventos e on e.lead_id = l.id and e.tipo = 'descreveu_caso'
where  l.origem is not null
order  by l.criado_em desc
limit  50;
