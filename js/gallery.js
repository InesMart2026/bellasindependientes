window.galleryHelpers = {
  // Escapa texto controlado por el usuario antes de meterlo en innerHTML.
  // El nombre/ubicación de una escort es contenido no confiable: sin esto,
  // "<img src=x onerror=...>" en el nombre ejecuta JS en cada visitante.
  escapeHtml(str) {
    return String(str ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  },

  async fetchEscorts(categoria = null) {
    // Solo perfiles pagos y vigentes. Destacadas primero (compraron posición),
    // luego por vencimiento más lejano. La RLS ya filtra visible_hasta, pero
    // lo repetimos acá para controlar el orden del grid.
    let query = window.supabaseClient
      .from('escorts')
      .select('*')
      .eq('activa', true)
      .gte('visible_hasta', new Date().toISOString())
      .order('destacada', { ascending: false })
      .order('visible_hasta', { ascending: false });

    if (categoria) query = query.eq('categoria', categoria);

    const { data, error } = await query;
    if (error) throw error;
    return data;
  },

  async fetchEscortBySlug(slug) {
    const { data, error } = await window.supabaseClient
      .rpc('get_escort_decrypted', { slug_param: slug })
      .single();
    if (error) throw error;
    return data;
  },

  async fetchPhotos(escortId) {
    const { data, error } = await window.supabaseClient
      .from('photos')
      .select('*')
      .eq('escort_id', escortId)
      .order('orden', { ascending: true });
    if (error) throw error;
    return data;
  },

  async fetchPortada(escortId) {
    const { data, error } = await window.supabaseClient
      .from('photos')
      .select('url')
      .eq('escort_id', escortId)
      .eq('es_portada', true)
      .maybeSingle();
    if (error) return { url: '/img/sin-foto.svg' };
    return data || { url: '/img/sin-foto.svg' };
  },

  renderCard(escort, portadaUrl) {
    const esc = this.escapeHtml;
    const div = document.createElement('a');
    div.className = 'card';
    // slug va en un atributo URL: encodeURIComponent evita romper el href / inyectar.
    div.href = `/perfil.html?slug=${encodeURIComponent(escort.slug)}`;
    const edad = Number.isInteger(escort.edad) ? ', ' + escort.edad : '';
    div.innerHTML = `
      <img class="card-img" src="${esc(portadaUrl)}" alt="${esc(escort.nombre)}" loading="lazy">
      <span class="card-badge">${esc(escort.categoria)}</span>
      <div class="card-body">
        <h3>${esc(escort.nombre)}${edad}</h3>
        <p>${esc(escort.ubicacion || '')}</p>
      </div>
    `;
    return div;
  },

  renderEmptyCard() {
    const div = document.createElement('a');
    div.className = 'card card--empty';
    div.href = '/planes.html';
    div.innerHTML = `
      <div class="card-empty-inner">
        <span class="card-empty-plus">+</span>
        <h3>Tu Espacio Aquí</h3>
        <p>Publicá tu perfil</p>
      </div>
    `;
    return div;
  },

  renderPhotoGrid(photos, containerId) {
    const container = document.getElementById(containerId);
    if (!container) return;
    container.innerHTML = '';
    photos.forEach(photo => {
      const img = document.createElement('img');
      img.src = photo.url;
      img.loading = 'lazy';
      img.addEventListener('click', () => this.openLightbox(photo.url));
      container.appendChild(img);
    });
  },

  openLightbox(url) {
    const lb = document.getElementById('lightbox');
    if (!lb) return;
    const img = lb.querySelector('img');
    img.src = url;
    lb.classList.add('active');
  },

  closeLightbox() {
    const lb = document.getElementById('lightbox');
    if (lb) lb.classList.remove('active');
  },

  filterEscorts(escorts, { search, edadMin, edadMax, sort } = {}) {
    let filtered = escorts ? [...escorts] : [];

    if (search) {
      const q = search.toLowerCase();
      filtered = filtered.filter(e =>
        (e.nombre || '').toLowerCase().includes(q) ||
        (e.ubicacion || '').toLowerCase().includes(q)
      );
    }

    if (edadMin) {
      filtered = filtered.filter(e => e.edad && e.edad >= parseInt(edadMin));
    }

    if (edadMax) {
      filtered = filtered.filter(e => e.edad && e.edad <= parseInt(edadMax));
    }

    if (sort === 'nombre') {
      filtered.sort((a, b) => (a.nombre || '').localeCompare(b.nombre || ''));
    } else {
      filtered.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    }

    return filtered;
  },

  async renderGrid(escorts, containerId) {
    const grid = document.getElementById(containerId);
    if (!grid) return;
    grid.classList.add('filtering');
    grid.innerHTML = '';

    if (escorts.length === 0) {
      grid.innerHTML = '<p style="grid-column:1/-1;text-align:center;padding:3rem 1rem;color:var(--text-secondary);">No encontramos perfiles con esos filtros.</p>';
      grid.classList.remove('filtering');
      return;
    }

    for (const escort of escorts) {
      const portada = await this.fetchPortada(escort.id);
      grid.appendChild(this.renderCard(escort, portada.url));
    }
    grid.classList.remove('filtering');
  },

  async renderSlots(escorts, containerId, totalSlots = 12) {
    const grid = document.getElementById(containerId);
    if (!grid) return;
    grid.classList.add('filtering');
    grid.innerHTML = '';

    const ocupadas = (escorts || []).slice(0, totalSlots);
    for (const escort of ocupadas) {
      const portada = await this.fetchPortada(escort.id);
      grid.appendChild(this.renderCard(escort, portada.url));
    }

    // Rellenar los slots restantes con "Tu Espacio Aquí"
    for (let i = ocupadas.length; i < totalSlots; i++) {
      grid.appendChild(this.renderEmptyCard());
    }
    grid.classList.remove('filtering');
  }
};

document.addEventListener('click', (e) => {
  if (e.target.closest('.lightbox') && !e.target.closest('.lightbox img')) {
    window.galleryHelpers.closeLightbox();
  }
});
