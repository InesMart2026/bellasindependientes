window.uploadHelpers = {
  // Solo imágenes reales, hasta 5MB. El accept="image/*" del input es UI:
  // se saltea desde la consola. Esta es la validación efectiva del cliente.
  // (La barrera dura debe estar también en la policy del bucket en Supabase.)
  MAX_BYTES: 5 * 1024 * 1024,
  ALLOWED_TYPES: ['image/jpeg', 'image/png', 'image/webp'],
  EXT_BY_TYPE: { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' },

  async uploadPhoto(escortId, file) {
    if (!this.ALLOWED_TYPES.includes(file.type)) {
      throw new Error('Formato no permitido. Usá JPG, PNG o WebP.');
    }
    if (file.size > this.MAX_BYTES) {
      throw new Error('La imagen supera los 5MB.');
    }

    // Extensión derivada del tipo MIME, no del nombre del archivo (evita
    // que un nombre malicioso como "foto.php.jpg" defina el path).
    const ext = this.EXT_BY_TYPE[file.type];
    const fileName = `${escortId}/${Date.now()}.${ext}`;

    const { error: uploadError } = await window.supabaseClient
      .storage
      .from('escort-photos')
      .upload(fileName, file, { contentType: file.type });

    if (uploadError) throw uploadError;

    const { data: { publicUrl } } = window.supabaseClient
      .storage
      .from('escort-photos')
      .getPublicUrl(fileName);

    const { error: dbError } = await window.supabaseClient
      .from('photos')
      .insert({ escort_id: escortId, url: publicUrl });

    if (dbError) throw dbError;

    return publicUrl;
  },

  async deletePhoto(photoId) {
    const { error } = await window.supabaseClient
      .from('photos')
      .delete()
      .eq('id', photoId);

    if (error) throw error;
  },

  async setPortada(photoId) {
    const { error } = await window.supabaseClient
      .from('photos')
      .update({ es_portada: true })
      .eq('id', photoId);

    if (error) throw error;
  }
};
