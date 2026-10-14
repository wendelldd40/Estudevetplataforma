/**
 * Peças comuns das duas funções do Pix: ambiente, banco, token da Cakto e CORS.
 * Nada aqui vai para o navegador. As chaves secretas vêm das variáveis de
 * ambiente da função (Supabase > Edge Functions > Secrets).
 */

export const env = (k: string, padrao = ''): string => Deno.env.get(k) ?? padrao

/** Endereço da API da Cakto. Só muda em teste. */
export const CAKTO = env('CAKTO_API', 'https://api.cakto.com.br/public_api').replace(/\/+$/, '')

/**
 * Produto da vitrine -> oferta na Cakto. O id da oferta é o pedaço do link
 * de checkout antes do "_" (pay.cakto.com.br/ddq45yk_1149960 -> ddq45yk).
 * Para trocar sem publicar a função de novo, cadastre o segredo CAKTO_OFERTAS
 * com um JSON, por exemplo {"orcamento":"abc1234"}.
 */
const OFERTAS_PADRAO: Record<string, string> = {
  orcamento: 'ddq45yk',
  precificacao: '8bnbiut',
  pasta: 'vdnp33a',
  'kit-tres': '3z5s3sj',
}
export const NOMES: Record<string, string> = {
  orcamento: 'Orçamento personalizado',
  precificacao: 'Precificação completa',
  pasta: 'A pasta do autônomo',
  'kit-tres': 'As três juntas',
}
export function ofertas(): Record<string, string> {
  try {
    const extra = JSON.parse(env('CAKTO_OFERTAS', '{}')) as Record<string, unknown>
    const limpo = Object.fromEntries(Object.entries(extra).filter(([, v]) => typeof v === 'string' && v.trim()).map(([k, v]) => [k, String(v).trim()]))
    return { ...OFERTAS_PADRAO, ...limpo }
  } catch {
    return OFERTAS_PADRAO
  }
}

/* ------------------------------------------------------------------ erros */

export class Falha extends Error {
  constructor(public status: number, public codigo: string, mensagem: string) { super(mensagem) }
}

/* ------------------------------------------------------------------ CORS */

export function cabecalhos(req: Request): Record<string, string> {
  const origens = env('PIX_ORIGENS', '*').split(',').map(s => s.trim()).filter(Boolean)
  const origem = req.headers.get('origin') ?? ''
  const libera = origens.includes('*') ? '*' : origens.includes(origem) ? origem : origens[0] ?? 'null'
  return {
    'Access-Control-Allow-Origin': libera,
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info, x-admin',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  }
}

export function resposta(req: Request, status: number, corpo: unknown): Response {
  if (status === 204) return new Response(null, { status, headers: cabecalhos(req) })
  return new Response(JSON.stringify(corpo), { status, headers: cabecalhos(req) })
}

/* ------------------------------------------------------------------ banco */

/** PostgREST com a service_role. Só roda aqui dentro, nunca no navegador. */
export async function db<T = unknown>(caminho: string, init: RequestInit = {}): Promise<T> {
  const url = env('SUPABASE_URL').replace(/\/+$/, '')
  const chave = env('SUPABASE_SERVICE_ROLE_KEY')
  const r = await fetch(`${url}/rest/v1/${caminho}`, {
    ...init,
    headers: { apikey: chave, Authorization: `Bearer ${chave}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  })
  const texto = await r.text()
  if (!r.ok) throw new Falha(500, 'banco', `Banco respondeu ${r.status}: ${texto.slice(0, 300)}`)
  return (texto ? JSON.parse(texto) : null) as T
}

/* ------------------------------------------------------------------ token da Cakto */

let tokenMemoria: { valor: string; expira: number } | null = null

/**
 * O token vale cerca de 10 horas e a Cakto limita a emissão, então ele fica
 * guardado na memória da função e na tabela pix_config (que ninguém de fora lê).
 */
export async function tokenCakto(renovar = false): Promise<string> {
  const folga = 120_000
  if (!renovar && tokenMemoria && tokenMemoria.expira > Date.now() + folga) return tokenMemoria.valor
  if (!renovar) {
    const linhas = await db<{ valor: string; expira: string }[]>('pix_config?chave=eq.cakto_token&select=valor,expira').catch(() => [])
    const l = linhas?.[0]
    if (l && Date.parse(l.expira) > Date.now() + folga) {
      tokenMemoria = { valor: l.valor, expira: Date.parse(l.expira) }
      return l.valor
    }
  }
  const id = env('CAKTO_CLIENT_ID'), segredo = env('CAKTO_CLIENT_SECRET')
  if (!id || !segredo) throw new Falha(503, 'sem_credencial', 'Faltam CAKTO_CLIENT_ID e CAKTO_CLIENT_SECRET nos segredos da função.')
  const r = await fetch(`${CAKTO}/token/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: id, client_secret: segredo }),
  })
  if (!r.ok) throw new Falha(502, 'cakto_token', `A Cakto recusou as credenciais (${r.status}).`)
  const j = await r.json() as { access_token: string; expires_in?: number }
  const expira = Date.now() + (Number(j.expires_in) || 3600) * 1000
  tokenMemoria = { valor: j.access_token, expira }
  await db('pix_config?on_conflict=chave', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
    body: JSON.stringify({ chave: 'cakto_token', valor: j.access_token, expira: new Date(expira).toISOString() }),
  }).catch(() => { /* sem tabela, segue só com a memória */ })
  return j.access_token
}

/** Chamada à Cakto com o token. Se ele tiver vencido do lado de lá, pega outro e tenta uma vez. */
export async function cakto(caminho: string, init: RequestInit = {}): Promise<Response> {
  const chamar = async (renovar: boolean) => fetch(`${CAKTO}${caminho}`, {
    ...init,
    headers: { Authorization: `Bearer ${await tokenCakto(renovar)}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  })
  let r = await chamar(false)
  if (r.status === 401) r = await chamar(true)
  return r
}

/* ------------------------------------------------------------------ utilidades */

export const so = (t: unknown): string => String(t ?? '').replace(/\D/g, '')

export function cpfValido(v: string): boolean {
  const d = so(v)
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false
  const dig = (n: number) => {
    let s = 0
    for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i)
    const r = (s * 10) % 11
    return r === 10 ? 0 : r
  }
  return dig(9) === Number(d[9]) && dig(10) === Number(d[10])
}

export const emailValido = (v: string): boolean => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v.trim()) && v.length <= 160

export async function sha256(texto: string): Promise<string> {
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto))
  return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join('')
}

export async function hmacHex(chave: string, texto: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const s = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(texto))
  return [...new Uint8Array(s)].map(x => x.toString(16).padStart(2, '0')).join('')
}

/** Comparação em tempo constante, para o segredo não vazar pelo tempo de resposta. */
export function iguais(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b)
  let dif = x.length ^ y.length
  for (let i = 0; i < Math.max(x.length, y.length); i++) dif |= (x[i] ?? 0) ^ (y[i] ?? 0)
  return dif === 0
}

/** A Cakto devolve "2026-04-29 01:30:00+00:00"; vira ISO. */
export function dataIso(v: unknown): string | null {
  if (typeof v !== 'string' || !v) return null
  const t = Date.parse(v.includes('T') ? v : v.replace(' ', 'T'))
  return Number.isFinite(t) ? new Date(t).toISOString() : null
}

export const ESPERANDO = new Set(['waiting_payment', 'processing', 'authorized', 'retrying'])
