/**
 * admin-convidar: o admin manda o convite de acesso para quem comprou e ainda
 * não tem conta. Confere no servidor que quem pediu é admin (pelo token da
 * sessão) e só então usa a chave de serviço para chamar o convite do Supabase Auth.
 *
 *   supabase functions deploy admin-convidar
 * (com verificação de JWT ligada, que é o padrão)
 */
import { db, env } from '../_shared/comum.ts'
import { convidarPorEmail } from '../_shared/pagamentos.ts'

function cors(req: Request) {
  const origens = env('PLATAFORMA_ORIGENS', '*').split(',').map(s => s.trim())
  const o = req.headers.get('origin') ?? ''
  return {
    'Access-Control-Allow-Origin': origens.includes('*') ? '*' : origens.includes(o) ? o : origens[0] ?? 'null',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Content-Type': 'application/json', Vary: 'Origin',
  }
}

export async function atender(req: Request): Promise<Response> {
  const h = cors(req)
  const r = (s: number, c: unknown) => new Response(JSON.stringify(c), { status: s, headers: h })
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: h })
  if (req.method !== 'POST') return r(405, { mensagem: 'Use POST.' })

  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!token) return r(401, { mensagem: 'Entre na conta.' })
  const url = env('SUPABASE_URL').replace(/\/+$/, '')
  const quem = await fetch(`${url}/auth/v1/user`, { headers: { apikey: env('SUPABASE_ANON_KEY'), Authorization: `Bearer ${token}` } })
  if (!quem.ok) return r(401, { mensagem: 'Sessão expirada. Entre de novo.' })
  const u = await quem.json() as { id?: string }
  const [perfil] = await db<{ papel: string }[]>(`perfis?id=eq.${u.id}&select=papel`)
  if (perfil?.papel !== 'admin') return r(403, { mensagem: 'Só o admin manda convite.' })

  const corpo = await req.json().catch(() => ({})) as { email?: string; nome?: string | null }
  const email = String(corpo.email ?? '').trim().toLowerCase()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return r(400, { mensagem: 'E-mail inválido.' })
  const ja = await db<{ id: string }[]>(`perfis?email=eq.${encodeURIComponent(email)}&select=id`)
  if (ja.length) return r(409, { mensagem: 'Essa pessoa já tem conta. Mande o link de nova senha.' })
  const ok = await convidarPorEmail(email, corpo.nome ?? null)
  return ok ? r(200, { ok: true }) : r(502, { mensagem: 'O Supabase não mandou o convite. Confira o e-mail e as configurações de Auth.' })
}

if (import.meta.main) Deno.serve(atender)
