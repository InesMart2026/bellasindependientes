// Avisos legales de entrada: age-gate (+18) y banner de cookies.
// Un solo archivo, se autoinyecta. Se incluye en <head> de cada página pública.
// No depende de style.css ni de librerías — estilos propios inline.
(function () {
  'use strict';

  var AGE_KEY = 'ecr_age_ok';       // guarda timestamp de aceptación +18
  var COOKIE_KEY = 'ecr_cookies';   // guarda 'accepted' | 'rejected'
  var AGE_TTL_DAYS = 30;            // recordar el +18 por 30 días

  // --- helpers de persistencia (localStorage falla en modo incógnito viejo) ---
  function get(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }
  function set(key, val) {
    try { localStorage.setItem(key, val); } catch (e) {}
  }

  function ageConfirmed() {
    var raw = get(AGE_KEY);
    if (!raw) return false;
    var ts = parseInt(raw, 10);
    if (isNaN(ts)) return false;
    var days = (Date.now() - ts) / 86400000;
    return days < AGE_TTL_DAYS;
  }

  // --- estilos ---
  var css = ''
    + '.ecr-agegate{position:fixed;inset:0;z-index:9999;display:flex;align-items:center;'
    + 'justify-content:center;background:rgba(0,0,0,.92);backdrop-filter:blur(6px);'
    + '-webkit-backdrop-filter:blur(6px);padding:1.5rem;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}'
    + '.ecr-agegate__box{max-width:440px;width:100%;background:#0d0d0d;border:1px solid #2A2A2A;'
    + 'border-radius:12px;padding:2.5rem 2rem;text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.6)}'
    + '.ecr-agegate__logo{font-family:"Playfair Display",Georgia,serif;font-size:1.8rem;'
    + 'letter-spacing:4px;color:#D4AF37;margin:0 0 1.25rem}'
    + '.ecr-agegate__title{font-family:"Playfair Display",Georgia,serif;font-size:1.5rem;'
    + 'color:#FAFAFA;margin:0 0 .75rem;line-height:1.2}'
    + '.ecr-agegate__text{color:#9a9a9a;font-size:.92rem;line-height:1.6;margin:0 0 1.75rem}'
    + '.ecr-agegate__actions{display:flex;flex-direction:column;gap:.7rem}'
    + '.ecr-btn{display:block;width:100%;padding:.9rem 1rem;border-radius:8px;font-size:.95rem;'
    + 'font-weight:600;cursor:pointer;border:1px solid transparent;font-family:inherit;transition:all .15s}'
    + '.ecr-btn--primary{background:#D4AF37;color:#000}'
    + '.ecr-btn--primary:hover{background:#F5E6A3}'
    + '.ecr-btn--ghost{background:transparent;color:#888;border-color:#2A2A2A}'
    + '.ecr-btn--ghost:hover{color:#FAFAFA;border-color:#444}'
    + '.ecr-agegate__fine{color:#5a5a5a;font-size:.72rem;line-height:1.5;margin:1.5rem 0 0}'
    + '.ecr-agegate__fine a{color:#888;text-decoration:underline}'
    + '.ecr-noscroll{overflow:hidden}'
    // cookies
    + '.ecr-cookies{position:fixed;left:0;right:0;bottom:0;z-index:9998;'
    + 'background:#0d0d0d;border-top:1px solid #2A2A2A;padding:1.1rem 1.5rem;'
    + 'display:flex;align-items:center;gap:1.25rem;flex-wrap:wrap;justify-content:center;'
    + 'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;'
    + 'box-shadow:0 -8px 30px rgba(0,0,0,.4)}'
    + '.ecr-cookies__text{color:#9a9a9a;font-size:.85rem;line-height:1.5;flex:1 1 320px;max-width:640px;margin:0}'
    + '.ecr-cookies__text a{color:#D4AF37;text-decoration:underline}'
    + '.ecr-cookies__actions{display:flex;gap:.6rem;flex-shrink:0}'
    + '.ecr-cookies .ecr-btn{width:auto;padding:.6rem 1.4rem;font-size:.85rem}'
    + '@media(max-width:520px){.ecr-cookies__actions{width:100%}.ecr-cookies .ecr-btn{flex:1}}';

  function injectStyles() {
    var s = document.createElement('style');
    s.textContent = css;
    document.head.appendChild(s);
  }

  // --- banner de cookies ---
  function showCookies() {
    if (get(COOKIE_KEY)) return;
    var bar = document.createElement('div');
    bar.className = 'ecr-cookies';
    bar.setAttribute('role', 'region');
    bar.setAttribute('aria-label', 'Aviso de cookies');
    bar.innerHTML = ''
      + '<p class="ecr-cookies__text">Usamos cookies propias necesarias para el '
      + 'funcionamiento del sitio y tu sesión. No compartimos tus datos con terceros. '
      + 'Podés leer más en nuestra <a href="/legal/cookies.html">Política de cookies</a>.</p>'
      + '<div class="ecr-cookies__actions">'
      + '<button type="button" class="ecr-btn ecr-btn--ghost" data-ecr="cookie-reject">Rechazar</button>'
      + '<button type="button" class="ecr-btn ecr-btn--primary" data-ecr="cookie-accept">Aceptar</button>'
      + '</div>';
    document.body.appendChild(bar);

    bar.querySelector('[data-ecr="cookie-accept"]').addEventListener('click', function () {
      set(COOKIE_KEY, 'accepted');
      bar.remove();
    });
    bar.querySelector('[data-ecr="cookie-reject"]').addEventListener('click', function () {
      set(COOKIE_KEY, 'rejected');
      bar.remove();
    });
  }

  // --- age gate ---
  function showAgeGate() {
    document.documentElement.classList.add('ecr-noscroll');
    document.body.classList.add('ecr-noscroll');

    var overlay = document.createElement('div');
    overlay.className = 'ecr-agegate';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'ecr-age-title');
    overlay.innerHTML = ''
      + '<div class="ecr-agegate__box">'
      + '<p class="ecr-agegate__logo">Bellas Independientes</p>'
      + '<h2 class="ecr-agegate__title" id="ecr-age-title">Contenido para adultos</h2>'
      + '<p class="ecr-agegate__text">Este sitio contiene material explícito destinado '
      + 'exclusivamente a personas mayores de 18 años. Al ingresar declarás bajo tu '
      + 'responsabilidad que sos mayor de edad según la ley de tu país.</p>'
      + '<div class="ecr-agegate__actions">'
      + '<button type="button" class="ecr-btn ecr-btn--primary" data-ecr="age-yes">Soy mayor de 18 — Entrar</button>'
      + '<button type="button" class="ecr-btn ecr-btn--ghost" data-ecr="age-no">Salir</button>'
      + '</div>'
      + '<p class="ecr-agegate__fine">Al continuar aceptás las '
      + '<a href="/legal/condiciones.html">Condiciones de uso</a> y la '
      + '<a href="/legal/privacidad.html">Política de privacidad</a>.</p>'
      + '</div>';
    document.body.appendChild(overlay);

    overlay.querySelector('[data-ecr="age-yes"]').focus();

    overlay.querySelector('[data-ecr="age-yes"]').addEventListener('click', function () {
      set(AGE_KEY, String(Date.now()));
      document.documentElement.classList.remove('ecr-noscroll');
      document.body.classList.remove('ecr-noscroll');
      overlay.remove();
      showCookies();
    });
    overlay.querySelector('[data-ecr="age-no"]').addEventListener('click', function () {
      window.location.href = 'https://www.google.com';
    });
  }

  function init() {
    injectStyles();
    if (ageConfirmed()) {
      showCookies();
    } else {
      showAgeGate();
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
