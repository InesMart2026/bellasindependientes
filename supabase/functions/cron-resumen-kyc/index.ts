// Edge Function: resumen matinal de perfiles pendientes de revisión.
// Corre por schedule (una vez a la mañana, hora Argentina). Junta todo lo
// que se acumuló durante el silencio nocturno —los perfiles marcados en
// revisión manual que nunca se notificaron— y manda UN solo mail a Ines.
//
// Complementa al webhook-kyc: de día el webhook avisa al instante; de noche
// calla y estos casos quedan con notificada_at NULL hasta que este cron los
// junta. La RPC kyc_tomar_pendientes_sin_notificar los marca al leerlos, así
// que un caso ya avisado de día no se repite acá.
//
// Se protege con un secreto compartido en el header X-Cron-Key para que solo
// el scheduler la dispare (no queda expuesta como endpoint público útil).
//
// Secrets: CRON_SECRET, SB_URL, SB_SERVICE_ROLE, RESEND_API_KEY,
//          REVISION_TO, REVISION_FROM (estos tres opcionales; ver helper).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { enviarAvisoRevision } from '../_shared/notificar-revision.ts';

Deno.serve(async (req) => {
  // Solo el scheduler, con el secreto correcto.
  const cronKey = Deno.env.get('CRON_SECRET') ?? '';
  const provided = req.headers.get('x-cron-key') ?? '';
  if (!cronKey || cronKey !== provided) {
    return new Response('no autorizado', { status: 401 });
  }

  try {
    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    const { data, error } = await admin.rpc('kyc_tomar_pendientes_sin_notificar');
    if (error) {
      console.error('kyc_tomar_pendientes_sin_notificar error:', error);
      return new Response('rpc error', { status: 500 });
    }

    const nombres = (data ?? []).map((p: { nombre: string }) => p.nombre);
    if (!nombres.length) {
      // Nada acumulado de noche: no se manda mail vacío.
      return new Response(JSON.stringify({ ok: true, enviados: 0 }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      });
    }

    const ok = await enviarAvisoRevision(nombres);
    return new Response(JSON.stringify({ ok, enviados: nombres.length }), {
      status: ok ? 200 : 502, headers: { 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error(err);
    return new Response('error', { status: 500 });
  }
});
