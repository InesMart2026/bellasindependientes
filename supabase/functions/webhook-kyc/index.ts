// Edge Function: webhook de Didit (resultado de verificación KYC).
// Didit nos avisa cuando termina una verificación. Verificamos la FIRMA
// del webhook (no confiamos en el body) y aplicamos el veredicto vía la
// RPC activate_verification (SECURITY DEFINER, idempotente).
//
// Firma (API v3): Didit envía el header X-Signature-V2 = HMAC-SHA256 sobre
// el JSON re-serializado en forma canónica (claves ordenadas, separadores
// compactos, Unicode sin escapar), más X-Timestamp (segundos) con ventana
// anti-replay de 5 minutos. Se dejan fallbacks a X-Signature (sobre el raw
// body) y X-Signature-Simple por compatibilidad.
//
// Secrets: DIDIT_WEBHOOK_SECRET, SB_URL, SB_SERVICE_ROLE

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const REPLAY_WINDOW_S = 300; // 5 minutos

Deno.serve(async (req) => {
  try {
    // 1. Leer el body RAW (necesario para el fallback sobre bytes exactos)
    const raw = await req.text();
    const secret = Deno.env.get('DIDIT_WEBHOOK_SECRET') ?? '';

    const sigV2     = req.headers.get('x-signature-v2') ?? '';
    const sigRaw    = req.headers.get('x-signature') ?? '';
    const sigSimple = req.headers.get('x-signature-simple') ?? '';
    const timestamp = req.headers.get('x-timestamp') ?? '';

    if (!secret) {
      console.error('DIDIT_WEBHOOK_SECRET no configurado');
      return new Response('server misconfigured', { status: 500 });
    }

    // 2. Anti-replay: rechazar entregas con más de 5 minutos de antigüedad.
    if (timestamp) {
      const skew = Math.abs(Math.floor(Date.now() / 1000) - Number(timestamp));
      if (!Number.isFinite(skew) || skew > REPLAY_WINDOW_S) {
        console.error('Webhook fuera de la ventana anti-replay');
        return new Response('stale webhook', { status: 401 });
      }
    }

    let body: Record<string, unknown>;
    try {
      body = JSON.parse(raw);
    } catch {
      return new Response('invalid json', { status: 400 });
    }

    // 3. Verificar la firma. Se prueba V2 (canónico) → raw → simple.
    const valid = await verifySignature(body, raw, secret, {
      v2: sigV2,
      raw: sigRaw,
      simple: sigSimple,
      timestamp,
    });
    if (!valid) {
      console.error('Firma de webhook inválida');
      return new Response('invalid signature', { status: 401 });
    }

    const sessionId = typeof body.session_id === 'string' ? body.session_id : undefined;
    const status = typeof body.status === 'string' ? body.status : undefined;
    if (!sessionId || !status) return new Response('ok', { status: 200 });

    // Normalizar el status de Didit a nuestro CHECK constraint.
    const norm = status.toLowerCase();
    const mapped = ['approved', 'declined', 'pending', 'abandoned'].includes(norm)
      ? norm
      : 'pending';

    // Score de similitud facial si viene (0..1 o 0..100 según workflow).
    const decision = body.decision as Record<string, any> | undefined;
    const score = typeof decision?.face_match?.score === 'number'
      ? decision.face_match.score
      : null;

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    // 4. Aplicar el veredicto. activate_verification es idempotente y
    //    mapea approved→verificado, declined→rechazado, resto→en_revision.
    const { error } = await admin.rpc('activate_verification', {
      session_id: sessionId,
      new_status: mapped,
      new_score: score,
      payload: body,
    });
    if (error) {
      console.error('activate_verification error:', error);
      return new Response('rpc error', { status: 500 });
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response('error', { status: 500 });
  }
});

// Prueba las tres firmas de Didit. Basta con que una coincida.
async function verifySignature(
  body: Record<string, unknown>,
  raw: string,
  secret: string,
  sigs: { v2: string; raw: string; simple: string; timestamp: string },
): Promise<boolean> {
  // V2: HMAC sobre el JSON canónico (claves ordenadas, separadores compactos).
  if (sigs.v2) {
    const canonical = canonicalJson(body);
    if (await hmacEquals(canonical, sigs.v2, secret)) return true;
  }
  // Fallback: HMAC sobre el body crudo tal cual llegó.
  if (sigs.raw && await hmacEquals(raw, sigs.raw, secret)) return true;
  // Fallback simple: HMAC sobre "{ts}:{session_id}:{status}:{webhook_type}".
  if (sigs.simple) {
    const canon = `${sigs.timestamp}:${body.session_id}:${body.status}:${body.webhook_type}`;
    if (await hmacEquals(canon, sigs.simple, secret)) return true;
  }
  return false;
}

// Serialización canónica: claves ordenadas recursivamente, sin espacios.
// Equivale a json.dumps(sort_keys=True, separators=(",",":"), ensure_ascii=False).
function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value as Record<string, unknown>).sort();
  const parts = keys.map(
    (k) => `${JSON.stringify(k)}:${canonicalJson((value as Record<string, unknown>)[k])}`,
  );
  return `{${parts.join(',')}}`;
}

// HMAC-SHA256(payload) en hex, comparado en tiempo constante contra la firma.
async function hmacEquals(payload: string, signatureHex: string, secret: string): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const sigBuf = await crypto.subtle.sign('HMAC', key, enc.encode(payload));
  const expected = [...new Uint8Array(sigBuf)]
    .map((b) => b.toString(16).padStart(2, '0')).join('');

  const b = signatureHex.toLowerCase().replace(/^sha256=/, '');
  if (expected.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
