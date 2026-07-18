// Edge Function: panel de revisión manual de KYC (cola de Ines).
// Cuando la biometría de Didit cae en zona gris (85-90, o "In Review"),
// la escort queda en 'en_revision' con revision_manual=true (migración 019).
// Esta función deja a Ines ver esa cola y aprobar/rechazar cada caso.
//
// Autentica con la misma clave admin compartida (X-Admin-Key) que
// admin-reports/admin-bloquear. No la usa el público: la clave la ingresa
// el admin en el panel y viaja solo en el header.
//
// Acciones (campo `accion` del body):
//   'listar'   → devuelve los perfiles pendientes de revisión manual
//   'resolver' → aprueba o rechaza una sesión (session_id + aprobar:bool)
//
// Nunca expone datos sensibles (DNI, nombre real, selfie): el panel decide
// con score biométrico + foto pública. El documento se mira en Didit si hace
// falta. Así mantenemos mínima la superficie legal.
//
// Secrets requeridos:
//   ADMIN_API_KEY    → clave larga y aleatoria (la misma que admin-reports)
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
    const accion = typeof body.accion === 'string' ? body.accion : 'listar';

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    if (accion === 'listar') {
      const { data, error } = await admin.rpc('kyc_pendientes_manual');
      if (error) {
        console.error('kyc_pendientes_manual error:', error);
        return json({ error: 'no se pudo leer la cola' }, 500);
      }
      return json({ ok: true, pendientes: data ?? [] });
    }

    if (accion === 'resolver') {
      const sessionId = typeof body.session_id === 'string' ? body.session_id : '';
      const aprobar = body.aprobar === true;
      if (!sessionId) return json({ error: 'session_id requerido' }, 400);

      const { data, error } = await admin.rpc('resolver_revision_manual', {
        session_id: sessionId,
        aprobar,
      });
      if (error) {
        console.error('resolver_revision_manual error:', error);
        return json({ error: 'no se pudo resolver' }, 500);
      }
      // data === false: la sesión no estaba en la cola (ya resuelta o inexistente).
      if (data !== true) return json({ error: 'la sesión ya no está pendiente' }, 409);
      return json({ ok: true, aprobada: aprobar });
    }

    return json({ error: 'acción desconocida' }, 400);
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
