// Footer legal compartido — se inyecta en todas las páginas públicas.
// Un solo lugar para editar textos legales, links y el año del copyright.
(function () {
  const year = new Date().getFullYear();

  const html = `
    <footer class="footer">
      <div class="footer-inner">
        <nav class="footer-links" aria-label="Enlaces legales">
          <a href="/legal/aviso-legal.html">Aviso legal</a>
          <a href="/legal/condiciones.html">Condiciones de uso</a>
          <a href="/legal/privacidad.html">Política de privacidad</a>
          <a href="/legal/cookies.html">Política de cookies</a>
          <a href="/legal/dmca.html">DMCA</a>
          <a href="/legal/2257.html">Declaración 2257</a>
          <a href="/legal/denunciar-trata.html">Denunciar trata</a>
          <a href="/legal/proteccion-menores.html">Protección de menores</a>
          <a href="/legal/retiro-contenido.html">Retiro de contenido</a>
          <a href="/legal/contacto.html">Contacto</a>
        </nav>

        <div class="footer-disclaimer">
          <p>
            Bellas Escort es un directorio de anuncios. No somos una agencia de escorts ni
            intermediamos entre usuarios y anunciantes. Las fotos, textos y anuncios
            son publicados bajo la exclusiva responsabilidad de los propios usuarios
            que los publican.
          </p>
          <p>
            Sitio de contenido adulto exclusivo para mayores de 18 años. Todos los
            anunciantes han declarado y verificado ser mayores de edad. La protección
            de menores es una de nuestras principales prioridades: excluimos de forma
            definitiva a cualquier usuario que infrinja nuestras condiciones publicando
            contenido o imágenes prohibidas.
          </p>

          <p class="footer-brand">Bellas Escort</p>
          <p class="footer-legal-line">&copy; ${year} Bellas Escort — Todos los derechos reservados</p>

          <div class="footer-badges">
            <span class="footer-badge">+18</span>
            <a class="footer-badge" href="https://www.rtalabel.org" target="_blank" rel="noopener">RTA · RESTRICTED TO ADULTS</a>
            <!--
              BADGE ASACP: activar SOLO cuando Bellas Escort sea miembro afiliado de ASACP.
              Descargá el badge oficial desde tu panel de miembro en asacp.org
              (no desde Brandfetch), guardalo en /img/asacp.png y reemplazá este
              comentario por:
              <a href="https://www.asacp.org" target="_blank" rel="noopener">
                <img src="/img/asacp.png" alt="ASACP Member" height="34">
              </a>
            -->
          </div>
        </div>
      </div>

      <div class="footer-stop">
        <div class="footer-stop-inner">
          <div class="footer-stop-icon" aria-hidden="true">
            <img src="/img/dl-7jqxercpl8qv.png" alt="" width="110" height="110" loading="lazy">
          </div>
          <div class="footer-stop-text">
            <p class="footer-stop-title">STOP HUMAN TRAFFICKING</p>
            <p><strong>La trata de personas es aberrante.</strong> Bellas Escort trabaja
            activamente para que su plataforma no sea usada por tratantes ni por
            quienes limiten la libertad de otros.</p>
            <p>Si vos o alguien que conocés necesita ayuda, llamá a la
            <a href="tel:145"><strong>Línea 145</strong></a> (Argentina, gratuita, 24 h) o visitá
            <a href="https://trafficking.help" target="_blank" rel="noopener">trafficking.help</a>.</p>
          </div>
        </div>
      </div>
    </footer>`;

  const mount = document.getElementById('site-footer');
  if (mount) mount.innerHTML = html;
})();
