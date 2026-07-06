// Edge Function: webhook de MercadoPago.
// MP nos avisa cuando cambia el estado de un pago. Verificamos el pago
// CONTRA la API de MP (no confiamos en el body) y, si está aprobado,
// activamos el slot vía la RPC activate_slot (SECURITY DEFINER).
//
// Secrets: MP_ACCESS_TOKEN, SB_URL, SB_SERVICE_ROLE

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  try {
    // MP manda el id del pago por query (?id=&topic=payment) o en el body.
    const url = new URL(req.url);
    let paymentId = url.searchParams.get('id') || url.searchParams.get('data.id');
    const topic = url.searchParams.get('topic') || url.searchParams.get('type');

    if (!paymentId) {
      const body = await req.json().catch(() => ({}));
      paymentId = body?.data?.id ?? body?.id ?? null;
    }

    // Solo nos interesan notificaciones de pago
    if (topic && topic !== 'payment') return new Response('ignored', { status: 200 });
    if (!paymentId) return new Response('no id', { status: 200 });

    // 1. Verificar el pago real contra MercadoPago
    const mpRes = await fetch(
      `https://api.mercadopago.com/v1/payments/${paymentId}`,
      { headers: { 'Authorization': `Bearer ${Deno.env.get('MP_ACCESS_TOKEN')}` } },
    );
    if (!mpRes.ok) return new Response('mp lookup failed', { status: 200 });
    const payment = await mpRes.json();

    // external_reference = id de nuestro registro en pagos
    const pagoId = payment.external_reference;
    if (!pagoId) return new Response('sin external_reference', { status: 200 });

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    if (payment.status === 'approved') {
      // activate_slot es idempotente: si ya estaba aprobado, no duplica días.
      const { error } = await admin.rpc('activate_slot', {
        pago_id: pagoId,
        mp_payment: String(paymentId),
      });
      if (error) {
        console.error('activate_slot error:', error);
        return new Response('rpc error', { status: 500 });
      }
    } else if (payment.status === 'rejected' || payment.status === 'cancelled') {
      await admin.from('pagos').update({ status: payment.status }).eq('id', pagoId);
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response('error', { status: 500 });
  }
});
