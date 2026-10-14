/**
 * cakto-webhook: a Cakto avisa aqui quando o Pix é pago, recusado, reembolsado
 * ou estornado. A função confere a assinatura e atualiza o pedido na tabela,
 * e a tela de pagamento da vitrine percebe na próxima consulta.
 *
 * Publique SEM verificação de JWT (a Cakto não manda o token do Supabase):
 *   supabase functions deploy cakto-webhook --no-verify-jwt
 *
 * Validação, nesta ordem:
 *   1. Cabeçalhos X-Cakto-Timestamp e X-Cakto-Signature (v1=HMAC-SHA256 de "timestamp.corpo"),
 *      com tolerância de 5 minutos. É o método que a Cakto recomenda.
 *   2. Sem os cabeçalhos, o campo "secret" do corpo, comparado em tempo constante.
 * O segredo é o que a Cakto mostra ao criar o webhook: cadastre como CAKTO_WEBHOOK_SECRET.
 */
import { NOMES, db, env, hmacHex, iguais } from '../_shared/comum.ts'

const SITUACAO: Record<string, string> = {
  purchase_approved: 'paid',
  purchase_refused: 'refused',
  pix_gerado: 'waiting_payment',
  refund_requested: 'refund_requested',
  refund: 'refunded',
  chargeback: 'chargedback',
}

const ok = (corpo: unknown = { ok: true }, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } })

async function assinaturaValida(req: Request, bruto: string): Promise<boolean> {
  const segredo = env('CAKTO_WEBHOOK_SECRET')
  if (!segredo) { console.error('CAKTO_WEBHOOK_SECRET não cadastrado'); return false }
  const ts = req.headers.get('x-cakto-timestamp')
  const assinatura = req.headers.get('x-cakto-signature')
  if (ts && assinatura) {
    const n = Number(ts)
    const ms = n > 1e12 ? n : n * 1000
    if (!Number.isFinite(n) || Math.abs(Date.now() - ms) > 5 * 60_000) return false
    const esperado = `v1=${await hmacHex(segredo, `${ts}.${bruto}`)}`
    return assinatura.split(',').map(s => s.trim()).some(s => iguais(s, esperado))
  }
  try {
    const s = (JSON.parse(bruto) as { secret?: unknown }).secret
    return typeof s === 'string' && iguais(s, segredo)
  } catch {
    return false
  }
}

Deno.serve(async req => {
  if (req.method !== 'POST') return ok({ erro: 'metodo' }, 405)
  const bruto = await req.text()
  if (!(await assinaturaValida(req, bruto))) return ok({ erro: 'assinatura' }, 401)

  let corpo: { event?: string; data?: unknown }
  try { corpo = JSON.parse(bruto) } catch { return ok({ erro: 'json' }, 400) }
  const evento = String(corpo.event ?? '')
  const lista = (Array.isArray(corpo.data) ? corpo.data : [corpo.data]) as { id?: string; status?: string; paidAt?: string | null; refId?: string }[]

  let atualizados = 0
  try {
    for (const d of lista) {
      if (!d?.id || !/^[A-Za-z0-9-]{6,64}$/.test(d.id)) continue
      const nova = SITUACAO[evento] ?? d.status
      if (!nova) continue
      const linhas = await db<{ status: string; lead_id: string | null; produto: string; ref_id: string | null }[]>(
        `pagamentos_pix?pedido_id=eq.${d.id}&select=status,lead_id,produto,ref_id`)
      const l = linhas[0]
      /* pedido feito no checkout da Cakto, fora da vitrine: não é com a gente */
      if (!l || l.status === nova) continue
      const agora = new Date().toISOString()
      await db(`pagamentos_pix?pedido_id=eq.${d.id}`, {
        method: 'PATCH', headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({
          status: nova, atualizado_em: agora, verificado_em: agora,
          ...(nova === 'paid' ? { pago_em: d.paidAt ?? agora } : {}),
        }),
      })
      atualizados++
      if (nova === 'paid' && l.lead_id) {
        await db('lead_eventos', {
          method: 'POST', headers: { Prefer: 'return=minimal' },
          body: JSON.stringify({
            lead_id: l.lead_id, tipo: 'abriu_produto', prazo: null,
            detalhe: `Pagou no Pix pela vitrine: ${NOMES[l.produto] ?? l.produto}${l.ref_id ? ` (pedido ${l.ref_id})` : ''}`,
          }),
        }).catch(e => console.error('lead_eventos', e))
      }
    }
  } catch (e) {
    /* responde 500 para aparecer como falha no histórico da Cakto e dar para reenviar de lá */
    console.error('webhook', e)
    return ok({ erro: 'banco' }, 500)
  }
  return ok({ ok: true, evento, atualizados })
})
