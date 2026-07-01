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
  }
};

document.addEventListener('click', (e) => {
  if (e.target.closest('.lightbox') && !e.target.closest('.lightbox img')) {
    window.galleryHelpers.closeLightbox();
  }
});
