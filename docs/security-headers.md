# Headers de seguridad — pendiente de aplicar al publicar

El sitio es HTML estático, así que estos headers se configuran en el **host**,
no en el código. Son defensa en profundidad: aunque quede algún XSS, la CSP
limita el daño (bloquea scripts inline no autorizados y exfiltración de datos).

## Qué headers y por qué

| Header | Valor | Protege contra |
|---|---|---|
| `Content-Security-Policy` | ver abajo | XSS, inyección de scripts, exfiltración |
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains; preload` | downgrade a HTTP, MITM |
| `X-Frame-Options` | `DENY` | clickjacking (embeber el sitio en un iframe) |
| `X-Content-Type-Options` | `nosniff` | MIME sniffing |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | fuga de URLs con datos a terceros |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | abuso de APIs del navegador |

## CSP recomendada

Ajustá los dominios de Supabase/MercadoPago a los tuyos. `'unsafe-inline'` en
`script-src` es necesario porque las páginas tienen `<script>` inline; para
eliminarlo habría que mover ese JS a archivos externos (mejora futura).

```
default-src 'self';
script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net;
style-src 'self' 'unsafe-inline';
img-src 'self' data: https://nvhjnopnonsrbyyvalvx.supabase.co;
connect-src 'self' https://nvhjnopnonsrbyyvalvx.supabase.co;
frame-src https://verification.didit.me https://www.mercadopago.com.ar;
frame-ancestors 'none';
base-uri 'self';
form-action 'self' https://www.mercadopago.com.ar;
```

## Cómo aplicarlo según host

### Vercel — `vercel.json` en la raíz
```json
{
  "headers": [{
    "source": "/(.*)",
    "headers": [
      { "key": "Strict-Transport-Security", "value": "max-age=63072000; includeSubDomains; preload" },
      { "key": "X-Frame-Options", "value": "DENY" },
      { "key": "X-Content-Type-Options", "value": "nosniff" },
      { "key": "Referrer-Policy", "value": "strict-origin-when-cross-origin" },
      { "key": "Permissions-Policy", "value": "camera=(), microphone=(), geolocation=()" },
      { "key": "Content-Security-Policy", "value": "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://nvhjnopnonsrbyyvalvx.supabase.co; connect-src 'self' https://nvhjnopnonsrbyyvalvx.supabase.co; frame-src https://verification.didit.me https://www.mercadopago.com.ar; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://www.mercadopago.com.ar" }
    ]
  }]
}
```

### Netlify / Cloudflare Pages — archivo `_headers` en la raíz
```
/*
  Strict-Transport-Security: max-age=63072000; includeSubDomains; preload
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=()
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://nvhjnopnonsrbyyvalvx.supabase.co; connect-src 'self' https://nvhjnopnonsrbyyvalvx.supabase.co; frame-src https://verification.didit.me https://www.mercadopago.com.ar; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://www.mercadopago.com.ar
```

## Verificación post-deploy
1. https://securityheaders.com — apuntar al dominio, objetivo: A o A+
2. Abrir la consola del navegador y confirmar que no hay errores de CSP que
   rompan Supabase, el checkout de MP o el widget de Didit.
