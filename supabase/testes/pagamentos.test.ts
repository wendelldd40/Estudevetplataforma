/**
 * Testa o webhook de pagamento e o convite sem internet: banco, Auth e Asaas são simulados.
 *   deno test -A supabase/testes/pagamentos.test.ts
 */
function assert(c: unknown, msg = 'falhou'): asserts c { if (!c) throw new Error(msg) }
function igual(a: unknown, b: unknown, msg = '') { const x = JSON.stringify(a), y = JSON.stringify(b); if (x !== y) throw new Error(`${msg}: esperado ${y}, veio ${x}`) }

Deno.env.set('SUPABASE_URL', 'https://teste.supabase.co')
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'chave-servico')
Deno.env.set('SUPABASE_ANON_KEY', 'chave-anon')
Deno.env.set('CAKTO_WEBHOOK_SECRET', 'segredo-cakto')
Deno.env.set('ASAAS_WEBHOOK_TOKEN', 'token-asaas')
Deno.env.set('ASAAS_API_KEY', 'chave-asaas')
Deno.env.set('PLATAFORMA_URL', 'https://estudevet.com.br/plataforma/')

/* ---------- PostgREST simulado ---------- */
type L = Record<string, unknown>
const T: Record<string, L[]> = {}
const reset = () => {
  for (const k of Object.keys(T)) delete T[k]
  Object.assign(T, {
    perfis: [{ id: 'u-ana', email: 'ana@x.com', papel: 'aluno' }, { id: 'u-adm', email: 'adm@x.com', papel: 'admin' }],
    produtos: [{ id: 'p1', slug: 'precificacao', nome: 'Precificação', publicado: true, gratuito: false, arquivado: false }],
    produto_ofertas: [{ id: 'o1', produto_id: 'p1', provedor: 'cakto', oferta_id: 'B8BcHrY' }, { id: 'o2', produto_id: 'p1', provedor: 'asaas', oferta_id: 'link_123' }],
    acessos: [], pedidos: [], pedido_eventos: [], pagamento_eventos: [], registros_admin: [], pagamentos_pix: [{ pedido_id: 'pix-00001', status: 'waiting_payment' }],
  })
}
const UNICOS: Record<string, string[]> = { pagamento_eventos: ['provedor', 'chave'] }
let seq = 0
function casa(r: L, k: string, v: string): boolean {
  const [op, ...resto] = v.split('.'); const val = resto.join('.')
  if (op === 'eq') return String(r[k]) === decodeURIComponent(val)
  if (op === 'is') return val === 'null' ? r[k] == null : String(r[k]) === val
  if (op === 'in') return decodeURIComponent(val).replace(/^\(|\)$/g, '').split(',').map(s => s.replace(/^"|"$/g, '')).includes(String(r[k]))
  return true
}
const filtro = (rows: L[], q: URLSearchParams) => rows.filter(r => [...q.entries()].every(([k, v]) => ['select', 'on_conflict', 'limit', 'order'].includes(k) || casa(r, k, v)))
function rest(url: URL, init: RequestInit): Response {
  const t = url.pathname.split('/').pop()!, rows = T[t] ??= [], q = url.searchParams, m = init.method ?? 'GET'
  const prefer = new Headers(init.headers).get('prefer') ?? ''
  if (m === 'GET') return Response.json(filtro(rows, q))
  const corpo = JSON.parse(String(init.body ?? '{}')) as L
  if (m === 'POST') {
    const u = UNICOS[t]
    if (u && rows.some(r => u.every(k => r[k] === corpo[k]))) return Response.json([], { status: 201 })
    const linha = { id: `${t.slice(0, 3)}-${++seq}`, criado_em: new Date().toISOString(), ...corpo }
    rows.push(linha)
    return prefer.includes('representation') ? Response.json([linha], { status: 201 }) : new Response(null, { status: 201 })
  }
  if (m === 'PATCH') { filtro(rows, q).forEach(r => Object.assign(r, corpo)); return new Response(null, { status: 204 }) }
  return new Response('?', { status: 400 })
}
const convites: L[] = []
globalThis.fetch = (async (entrada: string | URL | Request, init: RequestInit = {}) => {
  const url = new URL(typeof entrada === 'string' ? entrada : entrada instanceof URL ? entrada.href : entrada.url)
  if (url.pathname.startsWith('/rest/v1/')) {
    if (new Headers(init.headers).get('authorization') !== 'Bearer chave-servico') return new Response('{}', { status: 401 })
    return rest(url, init)
  }
  if (url.pathname === '/auth/v1/invite') { convites.push({ ...JSON.parse(String(init.body)), volta: url.searchParams.get('redirect_to') }); return Response.json({ id: 'novo' }) }
  if (url.pathname === '/auth/v1/user') {
    const tok = new Headers(init.headers).get('authorization')
    return tok === 'Bearer jwt-admin' ? Response.json({ id: 'u-adm' }) : tok === 'Bearer jwt-ana' ? Response.json({ id: 'u-ana' }) : new Response('{}', { status: 401 })
  }
  if (url.hostname === 'api.asaas.com' && url.pathname === '/v3/customers/cus_000005') {
    return new Headers(init.headers).get('access_token') === 'chave-asaas' ? Response.json({ id: 'cus_000005', email: 'Bia@X.com', name: 'Bia Souza' }) : new Response('{}', { status: 401 })
  }
  return new Response('fora do teste: ' + url.href, { status: 599 })
}) as typeof fetch

const { atender } = await import('../functions/pagamentos-webhook/index.ts')
const convidar = (await import('../functions/admin-convidar/index.ts')).atender

const cakto = (event: string, data: L, secret = 'segredo-cakto') =>
  atender(new Request('https://f/pagamentos-webhook?p=cakto', { method: 'POST', body: JSON.stringify({ secret, event, data }) }))
const asaas = (corpo: L, token = 'token-asaas') =>
  atender(new Request('https://f/pagamentos-webhook?p=asaas', { method: 'POST', headers: { 'asaas-access-token': token }, body: JSON.stringify(corpo) }))
const dadosCakto = (id: string, email: string, extra: L = {}) => ({ id, refId: 'AUAe5xK', customer: { name: 'Ana Lima', email }, offer: { id: 'B8BcHrY' }, product: { short_id: '49bruPi' }, status: 'paid', amount: 77, paymentMethod: 'pix', paidAt: '2026-10-10T10:00:00-03:00', ...extra })

Deno.test('Cakto: segredo errado é recusado e nada é gravado', async () => {
  reset()
  const r = await cakto('purchase_approved', dadosCakto('81b408ee-2a91-427d-80bd-226cbeae1fa0', 'ana@x.com'), 'chute')
  igual(r.status, 401, 'status'); igual(T.pedidos!.length, 0, 'pedidos'); igual(T.acessos!.length, 0, 'acessos')
})

Deno.test('Cakto: assinatura HMAC nos cabeçalhos também vale', async () => {
  reset()
  const corpo = JSON.stringify({ event: 'purchase_approved', data: dadosCakto('81b408ee-2a91-427d-80bd-226cbeae1fa1', 'ana@x.com') })
  const ts = String(Math.floor(Date.now() / 1000))
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode('segredo-cakto'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = [...new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${ts}.${corpo}`)))].map(b => b.toString(16).padStart(2, '0')).join('')
  const r = await atender(new Request('https://f/x?p=cakto', { method: 'POST', headers: { 'x-cakto-timestamp': ts, 'x-cakto-signature': `v1=${sig}` }, body: corpo }))
  igual(r.status, 200, 'status'); igual(T.acessos!.length, 1, 'acesso')
})

Deno.test('Cakto: compra aprovada libera, repetição não duplica, reembolso revoga', async () => {
  reset()
  const id = '81b408ee-2a91-427d-80bd-226cbeae1fa0'
  let r = await cakto('purchase_approved', dadosCakto(id, 'Ana@X.com'))
  igual(r.status, 200, 'status')
  igual(T.pedidos!.length, 1, 'pedido criado')
  const p = T.pedidos![0]!
  igual([p.status, p.total_centavos, p.metodo, p.codigo, p.user_id, p.email], ['pago', 7700, 'PIX', 'AUAe5xK', 'u-ana', 'ana@x.com'], 'pedido')
  igual(T.acessos!.map(a => [a.produto_id, a.email, a.user_id, a.origem, a.pedido_id]), [['p1', 'ana@x.com', 'u-ana', 'compra', p.id]], 'acesso')
  igual(convites.length, 0, 'quem já tem conta não recebe convite')

  r = await cakto('purchase_approved', dadosCakto(id, 'ana@x.com'))
  const j = await r.json() as { resultados: { duplicado?: boolean }[] }
  assert(j.resultados[0]?.duplicado, 'aviso repetido marcado como duplicado')
  igual(T.acessos!.length, 1, 'continua um acesso só')

  await cakto('refund', dadosCakto(id, 'ana@x.com', { status: 'refunded' }))
  igual(T.pedidos![0]!.status, 'reembolsado', 'pedido reembolsado')
  assert(T.acessos![0]!.revogado_em, 'acesso revogado')
  igual(T.pedido_eventos!.map(e => e.status), ['pago', 'reembolsado'], 'histórico')
  assert(T.registros_admin!.some(x => x.acao === 'acesso_revogado'), 'revogação registrada')

  /* aviso atrasado de "pix gerado" não desfaz nada */
  await cakto('pix_gerado', dadosCakto(id, 'ana@x.com', { status: 'waiting_payment' }))
  igual(T.pedidos![0]!.status, 'reembolsado', 'não volta para pendente')
})

Deno.test('Cakto: quem compra sem conta recebe convite e o acesso fica no e-mail', async () => {
  reset(); convites.length = 0
  await cakto('purchase_approved', dadosCakto('81b408ee-2a91-427d-80bd-226cbeae1fa2', 'nova@x.com'))
  igual(T.acessos!.map(a => [a.email, a.user_id]), [['nova@x.com', null]], 'acesso no e-mail')
  igual(convites.map(c => [c.email, c.volta]), [['nova@x.com', 'https://estudevet.com.br/plataforma/']], 'convite')
})

Deno.test('Cakto: oferta sem produto ligado não libera nada e avisa', async () => {
  reset()
  const r = await cakto('purchase_approved', { ...dadosCakto('81b408ee-2a91-427d-80bd-226cbeae1fa3', 'ana@x.com'), offer: { id: 'outra' }, product: { short_id: 'x' } })
  const j = await r.json() as { resultados: { aviso?: string }[] }
  igual(T.acessos!.length, 0, 'sem acesso'); igual(T.pedidos!.length, 1, 'pedido registrado mesmo assim')
  assert(j.resultados[0]?.aviso?.includes('nenhum produto'), 'aviso')
})

Deno.test('Cakto: Pix gerado na vitrine é atualizado em pagamentos_pix', async () => {
  reset()
  await cakto('purchase_approved', dadosCakto('pix-00001', 'ana@x.com'))
  igual(T.pagamentos_pix![0]!.status, 'paid', 'pagamentos_pix')
})

Deno.test('Asaas: token errado recusado; pagamento confirmado busca o e-mail e libera; chargeback revoga', async () => {
  reset()
  const corpo = (event: string, id: string) => ({ id, event, dateCreated: '2026-10-10 10:00:00', payment: { id: 'pay_080225913252', customer: 'cus_000005', value: 77, billingType: 'PIX', paymentLink: 'link_123', status: 'CONFIRMED' } })
  igual((await asaas(corpo('PAYMENT_CONFIRMED', 'evt_1'), 'errado')).status, 401, 'token')
  igual((await asaas(corpo('PAYMENT_CONFIRMED', 'evt_1'))).status, 200, 'ok')
  igual(T.acessos!.map(a => [a.email, a.produto_id]), [['bia@x.com', 'p1']], 'acesso pelo e-mail do cliente Asaas')
  igual(T.pedidos![0]!.nome, 'Bia Souza', 'nome')
  await asaas(corpo('PAYMENT_RECEIVED', 'evt_2'))
  igual(T.acessos!.length, 1, 'confirmado e recebido não liberam duas vezes')
  await asaas(corpo('PAYMENT_CHARGEBACK_REQUESTED', 'evt_3'))
  igual(T.pedidos![0]!.status, 'chargeback', 'status'); assert(T.acessos![0]!.revogado_em, 'revogado')
})

Deno.test('admin-convidar: só admin, e não convida quem já tem conta', async () => {
  reset(); convites.length = 0
  const pedir = (tok: string, email: string) => convidar(new Request('https://f/admin-convidar', { method: 'POST', headers: { authorization: `Bearer ${tok}` }, body: JSON.stringify({ email }) }))
  igual((await pedir('jwt-ana', 'x@x.com')).status, 403, 'aluno barrado')
  igual((await pedir('jwt-falso', 'x@x.com')).status, 401, 'token falso barrado')
  igual((await pedir('jwt-admin', 'ana@x.com')).status, 409, 'já tem conta')
  igual((await pedir('jwt-admin', 'nova@x.com')).status, 200, 'convite')
  igual(convites.length, 1, 'um convite'); assert(T.registros_admin!.some(r => r.acao === 'convite_enviado'), 'registrado')
})
