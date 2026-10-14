/**
 * pagamentos-webhook: recebe os avisos de pagamento e libera ou revoga o acesso.
 *
 *   Cakto: https://<projeto>.supabase.co/functions/v1/pagamentos-webhook?p=cakto
 *   Asaas: https://<projeto>.supabase.co/functions/v1/pagamentos-webhook?p=asaas
 *
 * Publique SEM verificação de JWT (o fornecedor não manda token do Supabase):
 *   supabase functions deploy pagamentos-webhook --no-verify-jwt
 *
 * Segredos (Supabase > Edge Functions > Secrets):
 *   CAKTO_WEBHOOK_SECRET   o segredo que a Cakto mostra ao criar o webhook
 *   ASAAS_WEBHOOK_TOKEN    o token que você define ao criar o webhook no Asaas
 *   ASAAS_API_KEY          (opcional) para buscar o e-mail do cliente no Asaas
 *   ASAAS_API              (opcional) https://api-sandbox.asaas.com para testes
 *   PLATAFORMA_URL         endereço da plataforma, para onde o convite leva
 *   CONVIDAR_NOVOS         "false" para não mandar convite a quem compra sem conta
 *   REVOGAR_EM_REEMBOLSO   "false" para não tirar o acesso em reembolso/contestação
 * SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda função.
 *
 * Respostas: 401 aviso não autêntico; 200 processado ou repetido; 500 falha
 * do nosso lado (o fornecedor tenta de novo e o aviso repetido não duplica nada).
 */
import { env } from '../_shared/comum.ts'
import { asaasAutentico, caktoAutentico, clienteAsaas, lerAsaas, lerCakto, processar, type Evento } from '../_shared/pagamentos.ts'

const json = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } })

export async function atender(req: Request): Promise<Response> {
  if (req.method !== 'POST') return json({ erro: 'metodo' }, 405)
  const provedor = new URL(req.url).searchParams.get('p') ?? 'cakto'
  const bruto = await req.text()
  if (bruto.length > 200_000) return json({ erro: 'grande' }, 413)

  let eventos: Evento[]
  try {
    if (provedor === 'cakto') {
      if (!(await caktoAutentico(req, bruto, env('CAKTO_WEBHOOK_SECRET')))) return json({ erro: 'assinatura' }, 401)
      eventos = lerCakto(JSON.parse(bruto))
    } else if (provedor === 'asaas') {
      if (!asaasAutentico(req, env('ASAAS_WEBHOOK_TOKEN'))) return json({ erro: 'token' }, 401)
      eventos = await lerAsaas(JSON.parse(bruto), clienteAsaas)
    } else return json({ erro: 'provedor' }, 400)
  } catch { return json({ erro: 'json' }, 400) }

  try {
    const resultados = []
    for (const e of eventos) resultados.push(await processar(e))
    return json({ ok: true, resultados })
  } catch (e) {
    console.error('pagamentos-webhook', e)
    return json({ erro: 'interno' }, 500)
  }
}

if (import.meta.main) Deno.serve(atender)
