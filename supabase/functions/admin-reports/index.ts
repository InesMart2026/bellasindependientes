// Edge Function: lista las denuncias para la administración.
// La tabla `reports` está cerrada por RLS (solo service_role). Esta función
// autentica con la misma clave admin compartida (X-Admin-Key) que
// admin-bloquear y devuelve las denuncias filtradas por estado.
//
// No la usa el público. La clave nunca se hardcodea en el frontend: el
// admin la ingresa en el panel y viaja solo en el header de la request.
//
// Secrets requeridos:
//   ADMIN_API_KEY    → clave larga y aleatoria (la misma que admin-bloquear)
//   SB_URL           → URL del proyecto Supabase
//   SB_SERVICE_ROLE  → service_role key (bypassa RLS)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, x-admin-key, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // Autorización admin por clave compartida, en tiempo constante.
    const adminKey = Deno.env.get('ADMIN_API_KEY') ?? '';
    const provided = req.headers.get('x-admin-key') ?? '';
    if (!adminKey || !constantTimeEquals(adminKey, provided)) {
      return json({ error: 'no autorizado' }, 401);
    }

    const body = await req.json().catch(() => ({}));
    // Filtro por estado: por defecto trae las que faltan revisar.
    const estado = typeof body.estado === 'string' ? body.estado : 'pendientes';

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    let query = admin
      .from('reports')
      .select('id, escort_id, slug, categoria, email, motivo, estado, created_at, resolved_at')
      .order('created_at', { ascending: false })
      .limit(200);

    if (estado === 'pendientes') {
      query = query.in('estado', ['nueva', 'en_revision']);
    } else if (['nueva', 'en_revision', 'resuelta', 'descartada'].includes(estado)) {
      query = query.eq('estado', estado);
    }
    // estado === 'todas' → sin filtro

    const { data, error } = await query;
    if (error) {
      console.error('admin-reports error:', error);
      return json({ error: 'no se pudieron leer las denuncias' }, 500);
    }

    return json({ ok: true, reports: data ?? [] });
  } catch (err) {
    console.error(err);
    return json({ error: 'error interno' }, 500);
  }
});

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
