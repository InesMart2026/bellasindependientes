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
    // después los planes por día, y al fondo los slots por hora: pagan menos
    // por la misma visibilidad, así que no compiten con quien compra días.
    // La RLS ya filtra visible_hasta, pero lo repetimos acá para el orden.
    let query = window.supabaseClient
      .from('escorts')
      .select('*')
      .eq('activa', true)
      .gte('visible_hasta', new Date().toISOString())
      .order('destacada', { ascending: false })
      .order('slot_por_hora', { ascending: true })
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

  // `minSlots` es un piso visual, NO un cupo: toda escort que pagó se muestra.
  // Sirve para que la grilla no se vea vacía cuando hay pocos perfiles y para
  // captar altas con las tarjetas "Tu Espacio Aquí".
  async renderSlots(escorts, containerId, minSlots = 12) {
    const grid = document.getElementById(containerId);
    if (!grid) return;
    grid.classList.add('filtering');
    grid.innerHTML = '';

    const ocupadas = escorts || [];
    for (const escort of ocupadas) {
      const portada = await this.fetchPortada(escort.id);
      grid.appendChild(this.renderCard(escort, portada.url));
    }

    // Relleno: hasta el piso visual y, pasado ese punto, solo lo justo para
    // cerrar la última fila. Sin esto la grilla queda con un hueco al final.
    const columnas = this.gridColumns(grid);
    const resto = ocupadas.length % columnas;
    const huecos = ocupadas.length < minSlots
      ? minSlots - ocupadas.length
      : (resto ? columnas - resto : 0);

    for (let i = 0; i < huecos; i++) {
      grid.appendChild(this.renderEmptyCard());
    }
    grid.classList.remove('filtering');
  },

  // Cantidad real de columnas del grid según el CSS vigente (varía por breakpoint).
  gridColumns(grid) {
    const cols = getComputedStyle(grid).gridTemplateColumns;
    const n = cols && cols !== 'none' ? cols.split(' ').length : 0;
    return n > 0 ? n : 1;
  }
};

document.addEventListener('click', (e) => {
  if (e.target.closest('.lightbox') && !e.target.closest('.lightbox img')) {
    window.galleryHelpers.closeLightbox();
  }
});
