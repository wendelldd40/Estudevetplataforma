/**
 * cakto-pix: o Pix da vitrine, sem sair da página.
 *
 *   { acao: "criar",  produto | produto_slug, cliente: { nome, email, telefone, cpf }, fingerprint, chave, lead_id?, rastreio? }
 *       -> cria a cobrança Pix na Cakto e devolve o copia e cola, a validade e o valor.
 *   { acao: "status", pedido }
 *       -> diz se já foi pago. Lê a tabela (o webhook atualiza) e, se ainda estiver
 *          esperando, confere direto na Cakto no máximo a cada 8 segundos.
 *   { acao: "conferir" }  com o cabeçalho x-admin = PIX_SENHA_ADMIN
 *       -> testa as credenciais e mostra se cada produto aponta para uma oferta que existe.
 *
 * produto       chave da vitrine (orcamento, precificacao...), com a oferta no código ou em CAKTO_OFERTAS
 * produto_slug  produto da plataforma: a oferta vem da tabela produto_ofertas (cadastrada no painel)
 *
 * O que fica guardado no nosso banco: número do pedido, produto, valor, situação,
 * o id do lead (que já existe no CRM) e um resumo irreversível do IP para limitar abuso.
 * Nome, e-mail, telefone e CPF vão direto para a Cakto e não são gravados aqui.
 */
import {
  CAKTO, ESPERANDO, Falha, NOMES, cakto, cpfValido, dataIso, db, emailValido, env, ofertas, resposta, sha256, so,
} from '../_shared/comum.ts'

interface Cliente { nome?: string; email?: string; telefone?: string; cpf?: string }
interface Pedido {
  acao?: string
  produto?: string
  produto_slug?: string
  cliente?: Cliente
  fingerprint?: string
  chave?: string
  lead_id?: string
  rastreio?: Record<string, unknown>
  pedido?: string
}

const RASTREIO_ACEITO = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content', 'sck']

async function criar(req: Request, p: Pedido) {
  let produto = String(p.produto ?? '')
  let oferta = ofertas()[produto]
  let nomeProduto = NOMES[produto] ?? produto
  if (p.produto_slug) {
    const slug = String(p.produto_slug)
    if (!/^[a-z0-9-]{2,80}$/.test(slug)) throw new Falha(400, 'produto', 'Produto inválido.')
    const [prod] = await db<{ id: string; nome: string; gratuito: boolean; arquivado: boolean | null }[]>(
      `produtos?slug=eq.${slug}&publicado=is.true&select=id,nome,gratuito,arquivado`)
    if (!prod || prod.arquivado || prod.gratuito) throw new Falha(400, 'produto_sem_pix', 'Este produto não está à venda.')
    const [of] = await db<{ oferta_id: string }[]>(`produto_ofertas?produto_id=eq.${prod.id}&provedor=eq.cakto&select=oferta_id&limit=1`)
    produto = slug; oferta = of?.oferta_id; nomeProduto = prod.nome
  }
  if (!oferta) throw new Falha(400, 'produto_sem_pix', 'Este produto não tem Pix ligado.')

  const c = p.cliente ?? {}
  const nome = String(c.nome ?? '').trim().replace(/\s+/g, ' ')
  const email = String(c.email ?? '').trim().toLowerCase()
  const tel = so(c.telefone)
  const cpf = so(c.cpf)
  if (nome.length < 5 || !nome.includes(' ') || nome.length > 120) throw new Falha(400, 'nome', 'Escreva o nome completo.')
  if (!emailValido(email)) throw new Falha(400, 'email', 'Confira o e-mail.')
  if (tel.length < 10 || tel.length > 11) throw new Falha(400, 'telefone', 'Confira o WhatsApp, com o DDD.')
  if (!cpfValido(cpf)) throw new Falha(400, 'cpf', 'Confira o CPF.')
  const chave = String(p.chave ?? '')
  if (!/^[A-Za-z0-9-]{16,64}$/.test(chave)) throw new Falha(400, 'chave', 'Pedido sem identificador.')
  const fingerprint = String(p.fingerprint ?? '').slice(0, 100)
  if (fingerprint.length < 8) throw new Falha(400, 'fingerprint', 'Pedido sem identificador do aparelho.')
  const leadId = typeof p.lead_id === 'string' && p.lead_id.length <= 64 ? p.lead_id : null

  /* limite simples contra quem tenta gerar Pix em série */
  const ip = (req.headers.get('x-forwarded-for') ?? '').split(',')[0]?.trim() ?? ''
  const ipHash = ip ? await sha256(`${ip}|${env('PIX_SAL', 'estudevet')}`) : null
  if (ipHash) {
    const desde = new Date(Date.now() - 15 * 60_000).toISOString()
    const recentes = await db<unknown[]>(`pagamentos_pix?ip_hash=eq.${ipHash}&criado_em=gte.${encodeURIComponent(desde)}&select=pedido_id`)
    if (recentes.length >= Number(env('PIX_LIMITE_15MIN', '5'))) throw new Falha(429, 'limite', 'Muitos Pix gerados em pouco tempo. Espere alguns minutos.')
  }

  const metadata = Object.fromEntries(Object.entries(p.rastreio ?? {})
    .filter(([k, v]) => RASTREIO_ACEITO.includes(k) && typeof v === 'string' && v.length <= 200))

  const corpo = {
    paymentMethod: 'pix',
    customer: {
      name: nome, email, phone: `55${tel}`, fingerprint, docType: 'cpf', docNumber: cpf,
      ...(ip ? { ip } : {}),
    },
    items: [{ offerId: oferta, quantity: 1, offerType: 'main' }],
    ...(Object.keys(metadata).length ? { metadata } : {}),
    pixExpiresIn: Number(env('PIX_VALIDADE_S', '1800')),
  }

  const r = await cakto('/payments/', { method: 'POST', headers: { 'X-Idempotency-Key': chave }, body: JSON.stringify(corpo) })
  const texto = await r.text()
  if (!r.ok) {
    console.error('cakto payments', r.status, texto.slice(0, 500))
    if (r.status === 429) throw new Falha(429, 'limite_cakto', 'A Cakto pediu um tempo. Tente de novo em um minuto.')
    if (r.status === 403) throw new Falha(502, 'escopo', 'A chave da Cakto está sem o escopo payments.')
    if (r.status === 409) throw new Falha(409, 'repetido', 'Esse Pix ainda está sendo gerado. Tente de novo em instantes.')
    throw new Falha(502, 'cakto_recusou', 'A Cakto não gerou o Pix agora.')
  }
  const j = JSON.parse(texto) as {
    id: string; refId?: string; status?: string; amount?: string | number
    pix?: { qrCode?: string; expirationDate?: string }
  }
  if (!j.id || !j.pix?.qrCode) throw new Falha(502, 'sem_qr', 'A Cakto respondeu sem o código Pix.')
  const valor = Number(j.amount)
  const expira = dataIso(j.pix.expirationDate) ?? new Date(Date.now() + Number(env('PIX_VALIDADE_S', '1800')) * 1000).toISOString()

  await db('pagamentos_pix?on_conflict=pedido_id', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({
      pedido_id: j.id, ref_id: j.refId ?? null, produto, oferta, valor: Number.isFinite(valor) ? valor : null,
      status: j.status ?? 'waiting_payment', lead_id: leadId, ip_hash: ipHash, expira_em: expira,
    }),
  })

  return {
    pedido: j.id,
    ref: j.refId ?? null,
    qrCode: j.pix.qrCode,
    expira,
    valor: Number.isFinite(valor) ? valor : null,
    produto: nomeProduto,
  }
}

async function status(p: Pedido) {
  const pedido = String(p.pedido ?? '')
  if (!/^[A-Za-z0-9-]{6,64}$/.test(pedido)) throw new Falha(400, 'pedido', 'Pedido inválido.')
  const linhas = await db<{ status: string; verificado_em: string; ref_id: string | null; valor: number | null }[]>(
    `pagamentos_pix?pedido_id=eq.${pedido}&select=status,verificado_em,ref_id,valor`)
  const l = linhas[0]
  /* só responde sobre pedido nascido aqui: a função não vira consulta de pedidos da Cakto */
  if (!l) throw new Falha(404, 'nao_achei', 'Pedido não encontrado.')
  let atual = l.status
  if (ESPERANDO.has(atual) && Date.now() - Date.parse(l.verificado_em) > 8000) {
    const r = await cakto(`/orders/${pedido}/`, { method: 'GET' })
    const agora = new Date().toISOString()
    if (r.ok) {
      const o = await r.json() as { status?: string; paidAt?: string | null }
      atual = o.status ?? atual
      await db(`pagamentos_pix?pedido_id=eq.${pedido}`, {
        method: 'PATCH', headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({ status: atual, verificado_em: agora, atualizado_em: agora, ...(o.paidAt ? { pago_em: o.paidAt } : {}) }),
      })
    } else {
      console.error('cakto orders', r.status)
      await db(`pagamentos_pix?pedido_id=eq.${pedido}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ verificado_em: agora }) })
    }
  }
  return { status: atual, pago: atual === 'paid', ref: l.ref_id, valor: l.valor }
}

async function conferir(req: Request) {
  const senha = env('PIX_SENHA_ADMIN')
  if (!senha || req.headers.get('x-admin') !== senha) throw new Falha(403, 'admin', 'Senha de administrador errada ou não cadastrada.')
  const r = await cakto('/offers/?limit=100', { method: 'GET' })
  const texto = await r.text()
  if (!r.ok) return { credenciais: r.status !== 401, erro: `A Cakto respondeu ${r.status} ao listar ofertas (a chave precisa do escopo offers para esta conferência).` }
  const j = JSON.parse(texto) as unknown
  const lista = (Array.isArray(j) ? j : (j as { results?: unknown[] }).results ?? []) as { id?: string; name?: string; price?: number; status?: string }[]
  return {
    credenciais: true,
    api: CAKTO,
    produtos: Object.entries(ofertas()).map(([produto, id]) => {
      const o = lista.find(x => x.id === id)
      return { produto, oferta: id, encontrada: Boolean(o), nome: o?.name ?? null, preco: o?.price ?? null, situacao: o?.status ?? null }
    }),
  }
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return resposta(req, 204, null)
  if (req.method !== 'POST') return resposta(req, 405, { erro: 'metodo', mensagem: 'Use POST.' })
  try {
    const p = await req.json().catch(() => ({})) as Pedido
    if (p.acao === 'criar') return resposta(req, 201, await criar(req, p))
    if (p.acao === 'status') return resposta(req, 200, await status(p))
    if (p.acao === 'conferir') return resposta(req, 200, await conferir(req))
    return resposta(req, 400, { erro: 'acao', mensagem: 'Ação desconhecida.' })
  } catch (e) {
    if (e instanceof Falha) {
      if (e.status >= 500) console.error(e.codigo, e.message)
      return resposta(req, e.status, { erro: e.codigo, mensagem: e.message })
    }
    console.error('falha inesperada', e)
    return resposta(req, 500, { erro: 'interno', mensagem: 'Algo deu errado do nosso lado.' })
  }
})
