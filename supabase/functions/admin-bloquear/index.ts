// Edge Function: acción ADMIN para bloquear un perfil y (opcional) sumar
// su DNI a la lista negra. NO la usa el público: exige una clave admin
// compartida (header X-Admin-Key) que solo tiene la administración.
//
// Flujo real: llega una denuncia (tabla reports), la administración la
// revisa, y si confirma la infracción invoca esta función con el escort_id.
// El bloqueo despublica el perfil y, si add_to_blacklist=true, veta el DNI
// para que no pueda re-registrarse (comparación por hash).
//
// Secrets requeridos:
//   ADMIN_API_KEY    → clave larga y aleatoria, solo en poder del admin
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
    // 1. Autorización admin por clave compartida, en tiempo constante.
    const adminKey = Deno.env.get('ADMIN_API_KEY') ?? '';
    const provided = req.headers.get('x-admin-key') ?? '';
    if (!adminKey || !constantTimeEquals(adminKey, provided)) {
      return json({ error: 'no autorizado' }, 401);
    }

    const body = await req.json().catch(() => ({}));
    const accion = typeof body.accion === 'string' ? body.accion : 'bloquear';
    const reportId = typeof body.report_id === 'string' ? body.report_id : null;

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    // Acción "descartar": la denuncia se revisó y no se comprueba. No bloquea.
    if (accion === 'descartar') {
      if (!reportId) return json({ error: 'report_id es obligatorio' }, 400);
      const { data, error } = await admin.rpc('dismiss_report', {
        report_id_param: reportId,
      });
      if (error) {
        console.error('dismiss_report error:', error);
        return json({ error: 'no se pudo descartar' }, 500);
      }
      return json(data ?? { ok: true });
    }

    // Acción "bloquear" (default): despublica y opcionalmente veta el DNI.
    const escortId = typeof body.escort_id === 'string' ? body.escort_id : '';
    const motivo = typeof body.motivo === 'string' ? body.motivo.trim() : '';
    const addToBlacklist = body.add_to_blacklist !== false; // default true

    if (!escortId || motivo.length < 3) {
      return json({ error: 'escort_id y motivo son obligatorios' }, 400);
    }

    const { data, error } = await admin.rpc('block_and_blacklist', {
      escort_id_param: escortId,
      motivo_param: motivo,
      add_to_blacklist: addToBlacklist,
      report_id_param: reportId,
    });

    if (error) {
      console.error('block_and_blacklist error:', error);
      return json({ error: 'no se pudo bloquear' }, 500);
    }

    return json(data ?? { ok: true });
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
