// Helper compartido: avisar a Ines que hay perfiles esperando revisión manual.
// Lo usan dos funciones:
//   · webhook-kyc      → aviso inmediato de día (un mail por perfil)
//   · cron-resumen-kyc → resumen matinal de lo acumulado de noche
//
// Regla de silencio nocturno: entre las 21:00 y las 8:00 (hora Argentina,
// UTC-3) NO se manda mail; los perfiles se acumulan y el cron matinal los
// junta en un solo resumen. De día se avisa al instante.
//
// El envío es por Resend (API). Secrets:
//   RESEND_API_KEY   → clave de API de Resend
//   REVISION_TO      → destino (default inesroxanamartinez@gmail.com)
//   REVISION_FROM    → remitente verificado (default legal@bellasindependientes.com)

const PANEL_URL = 'https://bellasindependientes.com/dashboard/revision.html';
const DEFAULT_TO = 'inesroxanamartinez@gmail.com';
const DEFAULT_FROM = 'Bellas Independientes <legal@bellasindependientes.com>';

// ¿Estamos en horario de silencio nocturno? 21:00–07:59 hora Argentina.
// El server corre en UTC; Argentina es UTC-3 fijo (sin DST). Se calcula la
// hora local restando 3, sin depender de la TZ del runtime.
export function esHorarioSilencio(now: Date = new Date()): boolean {
  const hArg = (now.getUTCHours() - 3 + 24) % 24;
  return hArg >= 21 || hArg < 8;
}

// Envía el mail. `nombres` es la lista de alias de los perfiles pendientes.
// Devuelve true si Resend aceptó el envío. Nunca lanza: un fallo de mail no
// debe tumbar el webhook (el perfil ya quedó en la cola igual).
export async function enviarAvisoRevision(nombres: string[]): Promise<boolean> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    console.error('RESEND_API_KEY no configurado — no se envía aviso');
    return false;
  }
  if (!nombres.length) return true;

  const to = Deno.env.get('REVISION_TO') || DEFAULT_TO;
  const from = Deno.env.get('REVISION_FROM') || DEFAULT_FROM;

  const n = nombres.length;
  const uno = n === 1;
  const subject = uno
    ? 'Un perfil espera tu revisión — Bellas Independientes'
    : `${n} perfiles esperan tu revisión — Bellas Independientes`;

  const esc = (s: string) =>
    s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
  const lista = nombres.map((x) => `<li>${esc(x)}</li>`).join('');

  const html = `
    <div style="font-family:system-ui,Arial,sans-serif;max-width:520px;margin:0 auto;color:#222">
      <h2 style="color:#111">${uno ? 'Hay un perfil para revisar' : `Hay ${n} perfiles para revisar`}</h2>
      <p>La verificación biométrica quedó en zona gris y necesita tu aprobación
         manual antes de publicarse:</p>
      <ul>${lista}</ul>
      <p style="margin:1.5rem 0">
        <a href="${PANEL_URL}"
           style="background:#d4af37;color:#111;padding:.7rem 1.4rem;border-radius:6px;
                  text-decoration:none;font-weight:600;display:inline-block">
          Abrir panel de revisión
        </a>
      </p>
      <p style="font-size:.8rem;color:#888">
        Necesitás la clave de administración para entrar. Este aviso se manda
        solo en horario diurno; de noche los perfiles se juntan en un resumen.
      </p>
    </div>`;

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from, to, subject, html }),
    });
    if (!res.ok) {
      console.error('Resend rechazó el envío:', res.status, await res.text());
      return false;
    }
    return true;
  } catch (err) {
    console.error('Error enviando aviso de revisión:', err);
    return false;
  }
}
