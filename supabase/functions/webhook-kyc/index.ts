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
import { esHorarioSilencio, enviarAvisoRevision } from '../_shared/notificar-revision.ts';

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

    // Scores de la decisión de Didit. El payload no es estable entre
    // workflows: face_match puede venir como objeto ({score}) o como
    // array (face_matches[].score); liveness igual (liveness{score} o
    // liveness_checks[].score). extractScore tolera ambas formas y se
    // queda con el mayor valor presente. Escala 0..100.
    const decision = body.decision as Record<string, any> | undefined;
    const faceScore = extractScore(decision, ['face_match', 'face_matches']);
    const livenessScore = extractScore(decision, ['liveness', 'liveness_checks']);

    const admin = createClient(
      Deno.env.get('SB_URL')!,
      Deno.env.get('SB_SERVICE_ROLE')!,
    );

    // 4. Aplicar el veredicto. activate_verification es idempotente:
    //    approved→verificado; "In Review" con face>=85 y liveness>=85
    //    →verificado (regla auditada, migración 018); resto→rechazado
    //    (la UI lo trata como reintento, no como bucle).
    const { error } = await admin.rpc('activate_verification', {
      session_id: sessionId,
      new_status: mapped,
      new_score: faceScore,
      payload: body,
      face_score: faceScore,
      liveness_score: livenessScore,
    });
    if (error) {
      console.error('activate_verification error:', error);
      return new Response('rpc error', { status: 500 });
    }

    // 5. Aviso a Ines si el caso cayó en revisión manual (zona gris). De día
    //    se avisa al instante; de noche se guarda silencio y el cron matinal
    //    manda el resumen. tomar_pendientes marca lo enviado para no repetir.
    //    Un fallo de mail no revierte nada: el perfil ya quedó en la cola.
    if (!esHorarioSilencio()) {
      try {
        const { data: pend } = await admin.rpc('kyc_tomar_pendientes_sin_notificar');
        const nombres = (pend ?? []).map((p: { nombre: string }) => p.nombre);
        if (nombres.length) await enviarAvisoRevision(nombres);
      } catch (mailErr) {
        console.error('aviso de revisión falló (no bloquea):', mailErr);
      }
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error(err);
    return new Response('error', { status: 500 });
  }
});

// Extrae un score de la decisión de Didit tolerando objeto o array.
// Prueba cada key: si es objeto usa .score; si es array toma el máximo
// .score de sus elementos. Devuelve el mayor valor hallado, o null.
function extractScore(
  decision: Record<string, any> | undefined,
  keys: string[],
): number | null {
  if (!decision) return null;
  let best: number | null = null;
  const consider = (n: unknown) => {
    if (typeof n === 'number' && Number.isFinite(n)) {
      best = best === null ? n : Math.max(best, n);
    }
  };
  for (const key of keys) {
    const node = decision[key];
    if (Array.isArray(node)) {
      for (const item of node) consider(item?.score);
    } else if (node && typeof node === 'object') {
      consider(node.score);
    }
  }
  return best;
}

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
