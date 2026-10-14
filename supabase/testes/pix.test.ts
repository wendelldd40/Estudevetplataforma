/**
 * Testa a função cakto-pix (vitrine e plataforma) sem internet: a Cakto e o banco são simulados aqui.
 *   deno test -A supabase/testes/pix.test.ts
 */
function assert(c: unknown, msg = 'falhou'): asserts c { if (!c) throw new Error(msg) }
function assertEquals(a: unknown, b: unknown, msg = '') { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`${msg} esperado ${y}, veio ${x}`) }

/* ---------- banco simulado (o pedaço do PostgREST que as funções usam) ---------- */
type Linha = Record<string, unknown>
const tabelas: Record<string, Linha[]> = { pagamentos_pix: [], pix_config: [], lead_eventos: [] }
const chaves: Record<string, string> = { pagamentos_pix: 'pedido_id', pix_config: 'chave' }
function filtra(rows: Linha[], q: URLSearchParams) {
  return rows.filter(r => [...q.entries()].every(([k, v]) => {
    if (['select', 'on_conflict', 'limit', 'order'].includes(k)) return true
    const [op, ...resto] = v.split('.'); const val = resto.join('.')
    if (op === 'eq') return String(r[k]) === val
    if (op === 'gte') return String(r[k]) >= val
    return true
  }))
}
function banco(url: URL, init: RequestInit): Response {
  const tabela = url.pathname.split('/').pop()!
  const rows = tabelas[tabela] ??= []
  const q = url.searchParams
  const metodo = init.method ?? 'GET'
  if (metodo === 'GET') {
    const sel = q.get('select')?.split(',')
    return Response.json(filtra(rows, q).map(r => sel ? Object.fromEntries(sel.map(c => [c, r[c] ?? null])) : r))
  }
  const corpo = JSON.parse(String(init.body ?? '{}'))
  if (metodo === 'POST') {
    const chave = chaves[tabela]
    const ja = chave ? rows.find(r => r[chave] === corpo[chave]) : undefined
    const agora = new Date().toISOString()
    if (ja) Object.assign(ja, corpo)
    else rows.push({ criado_em: agora, verificado_em: agora, ...corpo })
    return new Response(null, { status: 201 })
  }
  if (metodo === 'PATCH') { filtra(rows, q).forEach(r => Object.assign(r, corpo)); return new Response(null, { status: 204 }) }
  return new Response('?', { status: 400 })
}

/* ---------- Cakto simulada ---------- */
const cakto = { tokens: 0, cobrancas: [] as Linha[], pedidos: new Map<string, string>(), ultimaIdem: '' }
function apiCakto(url: URL, init: RequestInit): Response {
  const h = new Headers(init.headers)
  if (url.pathname.endsWith('/token/')) {
    const b = new URLSearchParams(String(init.body))
    if (b.get('client_secret') !== 'segredo-certo') return new Response('{}', { status: 401 })
    cakto.tokens++
    return Response.json({ access_token: `tok${cakto.tokens}`, expires_in: 36000, token_type: 'Bearer', scope: 'payments orders' })
  }
  if (!h.get('authorization')?.startsWith('Bearer tok')) return new Response('{}', { status: 401 })
  if (url.pathname.endsWith('/payments/') && init.method === 'POST') {
    const idem = h.get('x-idempotency-key') ?? ''
    if (!idem) return new Response('{"detail":"sem chave"}', { status: 400 })
    const b = JSON.parse(String(init.body))
    const existente = cakto.cobrancas.find(c => c.idem === idem)
    if (existente) return Response.json(existente.resposta, { status: 201 })
    if (!['ddq45yk', '8bnbiut', 'vdnp33a', '3z5s3sj'].includes(b.items[0].offerId)) return new Response('{"detail":"oferta"}', { status: 400 })
    const id = crypto.randomUUID()
    const preco: Record<string, string> = { ddq45yk: '47.00', '8bnbiut': '67.00', vdnp33a: '47.00', '3z5s3sj': '127.00' }
    const resposta = {
      id, refId: 'R' + id.slice(0, 6).toUpperCase(), status: 'waiting_payment', paymentMethod: 'pix', amount: preco[b.items[0].offerId],
      pix: { qrCode: '00020126580014br.gov.bcb.pix0136' + id + '5204000053039865406' + preco[b.items[0].offerId] + '5802BR6304ABCD', expirationDate: '2030-01-01 12:00:00+00:00', user_journey: null },
    }
    cakto.cobrancas.push({ idem, corpo: b, resposta }); cakto.pedidos.set(id, 'waiting_payment')
    return Response.json(resposta, { status: 201 })
  }
  const m = url.pathname.match(/\/orders\/([^/]+)\/$/)
  if (m) return cakto.pedidos.has(m[1]) ? Response.json({ id: m[1], status: cakto.pedidos.get(m[1]), paidAt: cakto.pedidos.get(m[1]) === 'paid' ? '2026-10-09T10:00:00-03:00' : null }) : new Response('{}', { status: 404 })
  if (url.pathname.endsWith('/offers/')) return Response.json({ results: [{ id: 'ddq45yk', name: 'Orçamento personalizado', price: 47, status: 'active' }, { id: '8bnbiut', name: 'Precificação completa', price: 67, status: 'active' }] })
  return new Response('{}', { status: 404 })
}

const fetchReal = globalThis.fetch
globalThis.fetch = (async (entrada: string | URL | Request, init: RequestInit = {}) => {
  const url = new URL(typeof entrada === 'string' ? entrada : entrada instanceof URL ? entrada.href : entrada.url)
  if (url.hostname === 'banco.teste') return banco(url, init)
  if (url.hostname === 'cakto.teste') return apiCakto(url, init)
  return fetchReal(entrada, init)
}) as typeof fetch

/* ---------- carrega as funções pegando o handler do Deno.serve ---------- */
Deno.env.set('SUPABASE_URL', 'https://banco.teste')
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service-falsa')
Deno.env.set('CAKTO_API', 'https://cakto.teste/public_api')
Deno.env.set('CAKTO_CLIENT_ID', 'id')
Deno.env.set('CAKTO_CLIENT_SECRET', 'segredo-certo')
Deno.env.set('CAKTO_WEBHOOK_SECRET', 'whsec_teste')
Deno.env.set('PIX_SENHA_ADMIN', 'admin123')
Deno.env.set('PIX_ORIGENS', 'https://estudevet.com.br')
type H = (r: Request) => Promise<Response>
const capturados: H[] = []
const serveReal = Deno.serve
;(Deno as unknown as { serve: unknown }).serve = (h: H) => { capturados.push(h); return { finished: Promise.resolve(), shutdown() {} } }
await import('../functions/cakto-pix/index.ts')
;(Deno as unknown as { serve: unknown }).serve = serveReal
const [pix] = capturados

const chamar = (corpo: unknown, cab: Record<string, string> = {}) => pix(new Request('https://f.teste/cakto-pix', {
  method: 'POST', headers: { 'content-type': 'application/json', origin: 'https://estudevet.com.br', 'x-forwarded-for': '200.1.2.3', ...cab }, body: JSON.stringify(corpo),
}))
const cliente = { nome: 'Marina Souza', email: 'marina@exemplo.com', telefone: '(79) 98888-7777', cpf: '529.982.247-25' }
const base = { acao: 'criar', produto: 'precificacao', cliente, fingerprint: 'fp-teste-123456', lead_id: 'lead-1', rastreio: { utm_source: 'meta', utm_campaign: 'pix', fbclid: 'nao-vai', utm_xpto: 'nao-vai' } }

Deno.test('CORS e preflight', async () => {
  const r = await pix(new Request('https://f.teste', { method: 'OPTIONS', headers: { origin: 'https://estudevet.com.br' } }))
  assertEquals(r.status, 204)
  assertEquals(r.headers.get('access-control-allow-origin'), 'https://estudevet.com.br')
})

Deno.test('recusa dado ruim antes de chamar a Cakto', async () => {
  for (const [campo, valor, erro] of [['cpf', '111.111.111-11', 'cpf'], ['email', 'marina@', 'email'], ['nome', 'Marina', 'nome'], ['telefone', '7999', 'telefone']] as const) {
    const r = await chamar({ ...base, chave: crypto.randomUUID(), cliente: { ...cliente, [campo]: valor } })
    assertEquals(r.status, 400); assertEquals((await r.json()).erro, erro)
  }
  const r = await chamar({ ...base, produto: 'crm', chave: crypto.randomUUID() })
  assertEquals((await r.json()).erro, 'produto_sem_pix')
  assertEquals(cakto.cobrancas.length, 0)
})

let pedido = ''
Deno.test('cria o Pix e não guarda dado pessoal', async () => {
  const chave = crypto.randomUUID()
  const r = await chamar({ ...base, chave })
  assertEquals(r.status, 201)
  const j = await r.json()
  pedido = j.pedido
  assert(j.qrCode.startsWith('000201')); assertEquals(j.valor, 67); assertEquals(j.produto, 'Precificação completa')
  assertEquals(j.expira, '2030-01-01T12:00:00.000Z')
  const enviado = cakto.cobrancas[0].corpo as { customer: Record<string, string>; items: { offerId: string }[]; metadata: Record<string, string> }
  assertEquals(enviado.customer.phone, '5579988887777'); assertEquals(enviado.customer.docNumber, '52998224725')
  assertEquals(enviado.items[0].offerId, '8bnbiut')
  assertEquals(enviado.metadata, { utm_source: 'meta', utm_campaign: 'pix' })
  const linha = tabelas.pagamentos_pix[0]
  assertEquals(linha.produto, 'precificacao'); assertEquals(linha.lead_id, 'lead-1'); assertEquals(linha.valor, 67)
  const tudo = JSON.stringify(tabelas.pagamentos_pix)
  for (const pessoal of ['Marina', 'marina@', '52998224725', '98888', '200.1.2.3']) assert(!tudo.includes(pessoal), 'vazou ' + pessoal)
  // repetir com a mesma chave não cria cobrança nova
  const r2 = await chamar({ ...base, chave })
  assertEquals((await r2.json()).pedido, pedido); assertEquals(cakto.cobrancas.length, 1)
  assertEquals(cakto.tokens, 1)
})

Deno.test('status: esperando, depois pago pela consulta direta', async () => {
  let j = await (await chamar({ acao: 'status', pedido })).json()
  assertEquals(j.pago, false)
  cakto.pedidos.set(pedido, 'paid')
  j = await (await chamar({ acao: 'status', pedido })).json()
  assertEquals(j.pago, false, 'dentro de 8 s não consulta a Cakto de novo')
  tabelas.pagamentos_pix[0].verificado_em = new Date(Date.now() - 9000).toISOString()
  j = await (await chamar({ acao: 'status', pedido })).json()
  assertEquals(j.pago, true); assertEquals(tabelas.pagamentos_pix[0].status, 'paid')
  const r = await chamar({ acao: 'status', pedido: 'pedido-de-outro-lugar' })
  assertEquals(r.status, 404)
})

async function assinar(corpo: string, ts: string, segredo = 'whsec_teste') {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(segredo), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const s = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${ts}.${corpo}`)))
  return 'v1=' + [...s].map(b => b.toString(16).padStart(2, '0')).join('')
}

Deno.test('limite de Pix por IP', async () => {
  let ultimo = 0
  for (let i = 0; i < 6; i++) ultimo = (await chamar({ ...base, chave: crypto.randomUUID() }, { 'x-forwarded-for': '10.0.0.9' })).status
  assertEquals(ultimo, 429)
})

Deno.test('conferir: precisa da senha e mostra as ofertas', async () => {
  assertEquals((await chamar({ acao: 'conferir' })).status, 403)
  const j = await (await chamar({ acao: 'conferir' }, { 'x-admin': 'admin123' })).json()
  assertEquals(j.credenciais, true)
  assertEquals(j.produtos.find((p: { produto: string }) => p.produto === 'orcamento').encontrada, true)
  assertEquals(j.produtos.find((p: { produto: string }) => p.produto === 'pasta').encontrada, false)
})

Deno.test('credencial errada vira erro claro', async () => {
  Deno.env.set('CAKTO_CLIENT_SECRET', 'errado'); tabelas.pix_config.length = 0
  const mod = await import('../functions/_shared/comum.ts')
  let msg = ''
  try { await mod.tokenCakto(true) } catch (e) { msg = (e as Error).message }
  assert(msg.includes('recusou as credenciais'))
  Deno.env.set('CAKTO_CLIENT_SECRET', 'segredo-certo')
})

Deno.test('plataforma: produto_slug usa a oferta cadastrada no painel', async () => {
  tabelas.produtos = [{ id: 'p-prec', slug: 'precificacao-autonomo', nome: 'Precificação do vet autônomo', publicado: true, gratuito: false, arquivado: false },
    { id: 'p-gratis', slug: 'gratis', nome: 'Grátis', publicado: true, gratuito: true, arquivado: false }]
  tabelas.produto_ofertas = [{ produto_id: 'p-prec', provedor: 'cakto', oferta_id: '8bnbiut' }]
  const antes = cakto.cobrancas.length
  const r = await chamar({ acao: 'criar', produto_slug: 'precificacao-autonomo', cliente, fingerprint: 'fp-teste-123456', chave: crypto.randomUUID() }, { 'x-forwarded-for': '200.9.9.9' })
  assertEquals(r.status, 201)
  const j = await r.json()
  assertEquals(j.produto, 'Precificação do vet autônomo')
  const enviado = cakto.cobrancas[antes].corpo as { items: { offerId: string }[] }
  assertEquals(enviado.items[0].offerId, '8bnbiut')
  const r2 = await chamar({ acao: 'criar', produto_slug: 'gratis', cliente, fingerprint: 'fp-teste-123456', chave: crypto.randomUUID() }, { 'x-forwarded-for': '200.9.9.8' })
  assertEquals((await r2.json()).erro, 'produto_sem_pix')
  const r3 = await chamar({ acao: 'criar', produto_slug: 'nao-existe', cliente, fingerprint: 'fp-teste-123456', chave: crypto.randomUUID() }, { 'x-forwarded-for': '200.9.9.7' })
  assertEquals((await r3.json()).erro, 'produto_sem_pix')
})
