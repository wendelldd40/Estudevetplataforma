/**
 * CAMADA DE PAGAMENTO DESACOPLADA DO FORNECEDOR
 *
 * Cada fornecedor tem um adaptador que faz duas coisas:
 *   1. confere se o aviso é autêntico, do jeito que a documentação dele manda;
 *   2. traduz o aviso para um Evento no formato da plataforma.
 * Daí para a frente (pedido, histórico, liberar ou revogar acesso, convite) é
 * igual para todos, em processar(). Trocar Cakto por Asaas é trocar o adaptador.
 *
 * Cakto (docs.cakto.com.br, Webhooks): corpo { secret, event, data }. O segredo
 *   vem no campo "secret" do corpo. Se vierem os cabeçalhos X-Cakto-Timestamp e
 *   X-Cakto-Signature, a assinatura HMAC-SHA256 também é conferida.
 *   data.id = pedido, data.refId = código curto, data.customer.email,
 *   data.offer.id = oferta, data.product.short_id = produto, data.amount em reais.
 * Asaas (docs.asaas.com, Webhooks): o token escolhido ao criar o webhook vem no
 *   cabeçalho asaas-access-token. Corpo { id, event, payment }. O e-mail do
 *   cliente não vem no aviso: é buscado em GET /v3/customers/{id} se houver
 *   ASAAS_API_KEY.
 */
import { db, env, hmacHex, iguais } from './comum.ts'

export type Tipo = 'pago' | 'pendente' | 'recusado' | 'cancelado' | 'expirado' | 'reembolsado' | 'chargeback' | 'ignorar'

export interface Evento {
  provedor: 'cakto' | 'asaas'
  chave: string              // identifica o aviso; o mesmo aviso repetido tem a mesma chave
  evento: string             // nome original do fornecedor
  tipo: Tipo
  pedidoExterno: string      // id do pedido/cobrança no fornecedor
  refCurta: string | null
  email: string | null
  nome: string | null
  valorCentavos: number | null
  metodo: string | null
  ofertas: string[]          // ids que podem estar em produto_ofertas
  pagoEm: string | null
}

export class AvisoInvalido extends Error { constructor(public status: number, m: string) { super(m) } }

const METODO: Record<string, string> = { pix: 'PIX', credit_card: 'CARTAO', boleto: 'BOLETO', picpay: 'PICPAY', CREDIT_CARD: 'CARTAO', PIX: 'PIX', BOLETO: 'BOLETO' }
const limpa = (v: unknown, max = 160) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null)

/* ------------------------------------------------------------------ Cakto */

const TIPO_CAKTO: Record<string, Tipo> = {
  purchase_approved: 'pago', purchase_refused: 'recusado', pix_gerado: 'pendente', boleto_gerado: 'pendente', picpay_gerado: 'pendente',
  refund: 'reembolsado', chargeback: 'chargeback',
}

export async function caktoAutentico(req: Request, bruto: string, segredo: string): Promise<boolean> {
  if (!segredo) return false
  const ts = req.headers.get('x-cakto-timestamp'), assinatura = req.headers.get('x-cakto-signature')
  if (ts && assinatura) {
    const n = Number(ts), ms = n > 1e12 ? n : n * 1000
    if (!Number.isFinite(n) || Math.abs(Date.now() - ms) > 5 * 60_000) return false
    const esperado = `v1=${await hmacHex(segredo, `${ts}.${bruto}`)}`
    if (assinatura.split(',').map(s => s.trim()).some(s => iguais(s, esperado))) return true
  }
  try { const s = (JSON.parse(bruto) as { secret?: unknown }).secret; return typeof s === 'string' && iguais(s, segredo) } catch { return false }
}

export function lerCakto(corpo: Record<string, unknown>): Evento[] {
  const evento = String(corpo.event ?? '')
  const lista = (Array.isArray(corpo.data) ? corpo.data : [corpo.data]) as Record<string, any>[]
  return lista.filter(d => d && typeof d.id === 'string' && /^[A-Za-z0-9-]{6,64}$/.test(d.id)).map(d => ({
    provedor: 'cakto' as const,
    chave: `${evento}:${d.id}`,
    evento,
    tipo: TIPO_CAKTO[evento] ?? 'ignorar',
    pedidoExterno: d.id,
    refCurta: limpa(d.refId, 20),
    email: limpa(d.customer?.email)?.toLowerCase() ?? null,
    nome: limpa(d.customer?.name, 120),
    valorCentavos: Number.isFinite(Number(d.amount)) ? Math.round(Number(d.amount) * 100) : null,
    metodo: METODO[String(d.paymentMethod ?? '')] ?? limpa(d.paymentMethod, 20),
    ofertas: [d.offer?.id, d.product?.short_id, d.product?.id].filter((x): x is string => typeof x === 'string' && !!x),
    pagoEm: limpa(d.paidAt, 40),
  }))
}

/* ------------------------------------------------------------------ Asaas */

const TIPO_ASAAS: Record<string, Tipo> = {
  PAYMENT_CREATED: 'pendente', PAYMENT_CONFIRMED: 'pago', PAYMENT_RECEIVED: 'pago', PAYMENT_OVERDUE: 'expirado',
  PAYMENT_DELETED: 'cancelado', PAYMENT_REFUNDED: 'reembolsado', PAYMENT_PARTIALLY_REFUNDED: 'reembolsado',
  PAYMENT_CHARGEBACK_REQUESTED: 'chargeback', PAYMENT_CHARGEBACK_DISPUTE: 'chargeback', PAYMENT_CREDIT_CARD_CAPTURE_REFUSED: 'recusado',
}

export function asaasAutentico(req: Request, token: string): boolean {
  const veio = req.headers.get('asaas-access-token') ?? ''
  return !!token && iguais(veio, token)
}

export async function lerAsaas(corpo: Record<string, any>, buscarCliente?: (id: string) => Promise<{ email?: string; name?: string } | null>): Promise<Evento[]> {
  const evento = String(corpo.event ?? '')
  const p = corpo.payment as Record<string, any> | undefined
  if (!p || typeof p.id !== 'string') return []
  const cliente = typeof p.customer === 'string' && buscarCliente ? await buscarCliente(p.customer).catch(() => null) : null
  /* externalReference pode trazer o slug do produto e o e-mail: "produto:slug;email:x@y" */
  const ref = String(p.externalReference ?? '')
  const pedacos = Object.fromEntries(ref.split(';').map(s => s.split(':')).filter(x => x.length >= 2).map(([k, ...v]) => [k!.trim(), v.join(':').trim()]))
  return [{
    provedor: 'asaas',
    chave: typeof corpo.id === 'string' && corpo.id ? corpo.id : `${evento}:${p.id}`,
    evento,
    tipo: TIPO_ASAAS[evento] ?? 'ignorar',
    pedidoExterno: p.id,
    refCurta: limpa(p.invoiceNumber, 20),
    email: (limpa(cliente?.email) ?? limpa(pedacos.email))?.toLowerCase() ?? null,
    nome: limpa(cliente?.name, 120),
    valorCentavos: Number.isFinite(Number(p.value)) ? Math.round(Number(p.value) * 100) : null,
    metodo: METODO[String(p.billingType ?? '')] ?? limpa(p.billingType, 20),
    ofertas: [p.paymentLink, pedacos.produto, ref && !ref.includes(':') ? ref : null].filter((x): x is string => typeof x === 'string' && !!x),
    pagoEm: limpa(p.confirmedDate ?? p.paymentDate, 40),
  }]
}

export async function clienteAsaas(id: string): Promise<{ email?: string; name?: string } | null> {
  const chave = env('ASAAS_API_KEY')
  if (!chave || !/^cus_[A-Za-z0-9]+$/.test(id)) return null
  const base = env('ASAAS_API', 'https://api.asaas.com').replace(/\/+$/, '')
  const r = await fetch(`${base}/v3/customers/${id}`, { headers: { access_token: chave, 'User-Agent': 'estudevet-plataforma' } })
  if (!r.ok) { console.error('asaas customers', r.status); return null }
  return await r.json() as { email?: string; name?: string }
}

/* ------------------------------------------------------------------ o que acontece com qualquer fornecedor */

interface Pedido { id: string; status: string; codigo: string | null; email: string | null; user_id: string | null }

/* um pedido pago não volta para pendente por causa de um aviso atrasado */
const PESO: Record<string, number> = { pendente: 0, expirado: 1, recusado: 1, cancelado: 1, pago: 2, reembolsado: 3, chargeback: 3 }
export const podeMudar = (de: string, para: string) => de !== para && (PESO[para] ?? 0) >= (PESO[de] ?? 0)

const codigo = () => Array.from(crypto.getRandomValues(new Uint8Array(6)), b => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[b % 32]).join('')
const enc = encodeURIComponent

async function registrar(acao: string, alvo_tipo: string, alvo_id: string, detalhe: Record<string, unknown>) {
  await db('registros_admin', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ ator_email: 'sistema', acao, alvo_tipo, alvo_id, detalhe }) })
    .catch(e => console.error('registros_admin', e))
}

export interface Resultado { duplicado?: boolean; pedido?: string; status?: string; liberados?: number; revogados?: number; convidado?: boolean; aviso?: string }

export async function processar(e: Evento): Promise<Resultado> {
  /* 1. idempotência: cada aviso entra uma vez */
  const novo = await db<{ id: string }[]>('pagamento_eventos?on_conflict=provedor,chave', {
    method: 'POST', headers: { Prefer: 'resolution=ignore-duplicates,return=representation' },
    body: JSON.stringify({ provedor: e.provedor, chave: e.chave, evento: e.evento }),
  })
  if (!novo?.length) return { duplicado: true }
  const idEvento = novo[0]!.id
  if (e.tipo === 'ignorar') { await fechar(idEvento, null, 'ignorado'); return { aviso: `evento ${e.evento} não muda nada` } }

  /* 2. pedido: acha pelo id do fornecedor ou cria */
  let [p] = await db<Pedido[]>(`pedidos?provedor=eq.${e.provedor}&provedor_pedido_id=eq.${enc(e.pedidoExterno)}&select=id,status,codigo,email,user_id`)
  const perfil = e.email ? (await db<{ id: string }[]>(`perfis?email=eq.${enc(e.email)}&select=id&limit=1`))[0] ?? null : null
  if (!p) {
    ;[p] = await db<Pedido[]>('pedidos', {
      method: 'POST', headers: { Prefer: 'return=representation' },
      body: JSON.stringify({
        codigo: e.refCurta ?? codigo(), nome: e.nome, email: e.email, total_centavos: e.valorCentavos ?? 0, status: e.tipo,
        metodo: e.metodo, provedor: e.provedor, provedor_pedido_id: e.pedidoExterno, user_id: perfil?.id ?? null, origem: 'webhook',
      }),
    })
    if (!p) throw new Error('pedido não foi criado')
  } else if (podeMudar(p.status, e.tipo)) {
    await db(`pedidos?id=eq.${p.id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ status: e.tipo, atualizado_em: new Date().toISOString(), ...(e.email && !p.email ? { email: e.email } : {}) }) })
  } else {
    await db('pedido_eventos', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ pedido_id: p.id, status: p.status, evento: e.evento, detalhe: { ignorado: `continua ${p.status}` } }) })
    await fechar(idEvento, p.id, `sem mudança (${p.status})`)
    return { pedido: p.id, status: p.status }
  }
  await db('pedido_eventos', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ pedido_id: p.id, status: e.tipo, evento: e.evento }) })
  await atualizarPixDaVitrine(e).catch(err => console.error('pagamentos_pix', err))

  const r: Resultado = { pedido: p.id, status: e.tipo }

  /* 3. pago: libera os produtos ligados às ofertas */
  if (e.tipo === 'pago') {
    if (!e.email) { r.aviso = 'pagamento sem e-mail: libere à mão em Compradores' }
    const lista = e.ofertas.length ? await db<{ produto_id: string }[]>(`produto_ofertas?provedor=eq.${e.provedor}&oferta_id=in.(${e.ofertas.map(o => `"${o.replace(/"/g, '')}"`).join(',')})&select=produto_id`) : []
    const produtos = [...new Set(lista.map(l => l.produto_id))]
    if (!produtos.length) r.aviso = `nenhum produto ligado às ofertas ${e.ofertas.join(', ') || '(vazio)'}`
    let liberados = 0
    for (const produto of e.email ? produtos : []) {
      const ja = await db<{ id: string }[]>(`acessos?email=eq.${enc(e.email!)}&produto_id=eq.${produto}&revogado_em=is.null&select=id`)
      if (ja.length) continue
      const [novoAcesso] = await db<{ id: string }[]>('acessos', {
        method: 'POST', headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ email: e.email, user_id: perfil?.id ?? null, produto_id: produto, origem: 'compra', pedido_id: p.id }),
      })
      liberados++
      await registrar('pagamento_aprovado', 'acesso', novoAcesso?.id ?? '', { email: e.email, produto_id: produto, pedido: p.codigo, provedor: e.provedor })
    }
    r.liberados = liberados
    if (liberados && !perfil && e.email && env('CONVIDAR_NOVOS', 'true') !== 'false') r.convidado = await convidarPorEmail(e.email, e.nome).catch(() => false)
  }

  /* 4. reembolso ou contestação: tira o acesso que este pedido liberou */
  if ((e.tipo === 'reembolsado' || e.tipo === 'chargeback') && env('REVOGAR_EM_REEMBOLSO', 'true') !== 'false') {
    const ativos = await db<{ id: string; email: string }[]>(`acessos?pedido_id=eq.${p.id}&revogado_em=is.null&select=id,email`)
    for (const a of ativos) {
      await db(`acessos?id=eq.${a.id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ revogado_em: new Date().toISOString(), motivo: e.tipo === 'chargeback' ? 'Contestação no meio de pagamento' : 'Reembolso no meio de pagamento' }) })
      await registrar('acesso_revogado', 'acesso', a.id, { email: a.email, motivo: e.evento, pedido: p.codigo })
    }
    r.revogados = ativos.length
  }
  await fechar(idEvento, p.id, JSON.stringify(r).slice(0, 300))
  return r
}

async function fechar(idEvento: string, pedido: string | null, resultado: string) {
  await db(`pagamento_eventos?id=eq.${idEvento}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ pedido_id: pedido, resultado }) }).catch(() => null)
}

/* o Pix gerado dentro da vitrine/plataforma também fica em pagamentos_pix; mantém os dois em dia */
const PIX: Partial<Record<Tipo, string>> = { pago: 'paid', recusado: 'refused', reembolsado: 'refunded', chargeback: 'chargedback', pendente: 'waiting_payment' }
async function atualizarPixDaVitrine(e: Evento) {
  if (e.provedor !== 'cakto' || !PIX[e.tipo]) return
  const agora = new Date().toISOString()
  await db(`pagamentos_pix?pedido_id=eq.${enc(e.pedidoExterno)}`, {
    method: 'PATCH', headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({ status: PIX[e.tipo], atualizado_em: agora, verificado_em: agora, ...(e.tipo === 'pago' ? { pago_em: e.pagoEm ?? agora } : {}) }),
  })
}

/** Convite oficial do Supabase Auth (POST /auth/v1/invite), com a chave de serviço. A pessoa recebe o e-mail e cria a senha. */
export async function convidarPorEmail(email: string, nome: string | null): Promise<boolean> {
  const url = env('SUPABASE_URL').replace(/\/+$/, ''), chave = env('SUPABASE_SERVICE_ROLE_KEY')
  const volta = env('PLATAFORMA_URL')
  const r = await fetch(`${url}/auth/v1/invite${volta ? `?redirect_to=${enc(volta)}` : ''}`, {
    method: 'POST', headers: { apikey: chave, Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, data: { nome: nome ?? undefined, origem: 'compra' } }),
  })
  if (!r.ok) { console.error('invite', r.status, (await r.text()).slice(0, 200)); return false }
  await registrar('convite_enviado', 'email', email, { email, origem: 'compra' })
  return true
}
