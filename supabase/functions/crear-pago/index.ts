// Edge Function: crea una preferencia de MercadoPago Checkout Pro.
// La escort (autenticada) elige un paquete → devolvemos el init_point.
// El slot NO se activa acá: solo lo activa el webhook al confirmarse el pago.
//
// Secrets requeridos (supabase secrets set ...):
//   MP_ACCESS_TOKEN   → Access Token de producción de tu cuenta MercadoPago
//   SITE_URL          → https://tu-dominio (para back_urls y webhook)
//   SB_URL            → URL del proyecto Supabase
//   SB_SERVICE_ROLE   → service_role key (bypassa RLS para insertar el pago)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    const { package_id } = await req.json();
    if (!package_id) return json({ error: 'package_id requerido' }, 400);

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
      .select('id, nombre, estado_verificacion')
      .eq('user_id', user.id)
      .single();
    if (!escort) return json({ error: 'no tenés un perfil creado' }, 400);

    // Gate legal: sin identidad verificada no se permite contratar.
    // El gate del cliente es solo UX; ésta es la barrera real (impide
    // publicar sin KYC aprobado, incl. verificación de mayoría de edad).
    if (escort.estado_verificacion !== 'verificado') {
      return json({ error: 'primero verificá tu identidad' }, 403);
    }

    // 2. Traer el paquete (precio autoritativo desde la DB, nunca del cliente)
    const { data: pkg } = await admin
      .from('packages')
      .select('*')
      .eq('id', package_id)
      .eq('activo', true)
      .single();
    if (!pkg) return json({ error: 'paquete inválido' }, 400);

    // 3. Registrar el pago pendiente
    // Un paquete dura días u horas (constraint en packages), nunca ambos.
    const { data: pago, error: pagoErr } = await admin
      .from('pagos')
      .insert({
        escort_id: escort.id,
        package_id: pkg.id,
        monto: pkg.precio_total,
        dias: pkg.dias ?? 0,
        horas: pkg.horas ?? 0,
        status: 'pending',
      })
      .select('id')
      .single();
    if (pagoErr || !pago) return json({ error: 'no se pudo registrar el pago' }, 500);

    // 4. Crear la preferencia en MercadoPago
    const siteUrl = Deno.env.get('SITE_URL')!;
    const pref = {
      items: [{
        title: `Bellas Escort — ${pkg.nombre} de visibilidad`,
        quantity: 1,
        unit_price: Number(pkg.precio_total),
        currency_id: 'ARS',
      }],
      external_reference: pago.id, // así el webhook sabe qué pago aprobar
      back_urls: {
        success: `${siteUrl}/dashboard/pago-exitoso.html`,
        failure: `${siteUrl}/planes.html`,
        pending: `${siteUrl}/dashboard/pago-exitoso.html`,
      },
      auto_return: 'approved',
      notification_url: `${Deno.env.get('SB_URL')}/functions/v1/webhook`,
    };

    const mpRes = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('MP_ACCESS_TOKEN')}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(pref),
    });
    const mpData = await mpRes.json();
    if (!mpRes.ok) {
      console.error('MP error:', mpData);
      return json({ error: 'MercadoPago rechazó la preferencia' }, 502);
    }

    await admin.from('pagos').update({ mp_preference_id: mpData.id }).eq('id', pago.id);

    return json({ init_point: mpData.init_point });
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
