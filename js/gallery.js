window.galleryHelpers = {
  async fetchEscorts(categoria = null) {
    let query = window.supabaseClient
      .from('escorts')
      .select('*')
      .eq('activa', true)
      .order('created_at', { ascending: false });

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
    if (error) return { url: 'https://via.placeholder.com/600x800?text=Sin+foto' };
    return data || { url: 'https://via.placeholder.com/600x800?text=Sin+foto' };
  },

  renderCard(escort, portadaUrl) {
    const div = document.createElement('a');
    div.className = 'card';
    div.href = `/perfil.html?slug=${escort.slug}`;
    div.innerHTML = `
      <img class="card-img" src="${portadaUrl}" alt="${escort.nombre}" loading="lazy">
      <span class="card-badge">${escort.categoria}</span>
      <div class="card-body">
        <h3>${escort.nombre}${escort.edad ? ', ' + escort.edad : ''}</h3>
        <p>${escort.ubicacion || ''}</p>
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
  }
};

document.addEventListener('click', (e) => {
  if (e.target.closest('.lightbox') && !e.target.closest('.lightbox img')) {
    window.galleryHelpers.closeLightbox();
  }
});
