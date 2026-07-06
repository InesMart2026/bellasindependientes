// Edge Function: crea una sesión de verificación de identidad en Didit.
// La escort (autenticada) inicia el KYC → devolvemos la URL del widget.
// El estado NO se marca verificado acá: eso lo hace el webhook-kyc al
// recibir el resultado de Didit (selfie vs DNI + liveness).
//
// Secrets requeridos (supabase secrets set ...):
//   DIDIT_API_KEY       → API key de tu cuenta Didit
//   DIDIT_WORKFLOW_ID   → ID del workflow de verificación (ID + liveness)
//   SB_URL              → URL del proyecto Supabase
//   SB_SERVICE_ROLE     → service_role key (bypassa RLS)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // 1. Identificar a la escort desde su JWT
    const authHeader = req.headers.get('Authorization') ?? '';
    const jwt = authHeader.replace('Bearer ', '');
    if (!jwt) return json({ error: 'no autenticado' }, 401);

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    const { data: { user }, error: userErr } = await admin.auth.getUser(jwt);
    if (userErr || !user) return json({ error: 'sesión inválida' }, 401);

    const { data: escort } = await admin
      .from('escorts')
      .select('id, estado_verificacion, acuerdo_legal')
      .eq('user_id', user.id)
      .single();
    if (!escort) return json({ error: 'primero completá tus datos' }, 400);

    // No re-verificar a quien ya está aprobada.
    if (escort.estado_verificacion === 'verificado') {
      return json({ error: 'tu identidad ya está verificada' }, 409);
    }
    // Debe haber aceptado el acuerdo legal antes de subir documentos.
    if (!escort.acuerdo_legal) {
      return json({ error: 'debés aceptar el acuerdo legal primero' }, 400);
    }

    // 2. Crear la sesión en Didit (API v3)
    const diditRes = await fetch('https://verification.didit.me/v3/session/', {
      method: 'POST',
      headers: {
        'X-Api-Key': Deno.env.get('DIDIT_API_KEY')!,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        workflow_id: Deno.env.get('DIDIT_WORKFLOW_ID'),
        // vendor_data nos permite mapear el resultado del webhook a la escort.
        vendor_data: escort.id,
      }),
    });
    const didit = await diditRes.json();
    if (!diditRes.ok) {
      console.error('Didit error:', didit);
      return json({ error: 'no se pudo iniciar la verificación' }, 502);
    }

    // 3. Registrar la sesión (idempotente por didit_session_id UNIQUE)
    await admin.from('kyc_verifications').insert({
      escort_id: escort.id,
      didit_session_id: didit.session_id,
      status: 'created',
    });

    // 4. Marcar a la escort como en revisión mientras completa el flujo
    await admin.from('escorts')
      .update({ estado_verificacion: 'en_revision' })
      .eq('id', escort.id);

    // v3 devuelve session_url; se mantiene fallback a url por compatibilidad.
    const sessionUrl = didit.session_url ?? didit.url;
    return json({ url: sessionUrl, session_id: didit.session_id });
  } catch (err) {
    console.error(err);
    return json({ error: 'error interno' }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}
