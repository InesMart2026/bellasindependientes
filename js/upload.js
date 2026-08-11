window.uploadHelpers = {
  // Solo imágenes reales, hasta 5MB. El accept="image/*" del input es UI:
  // se saltea desde la consola. Esta es la validación efectiva del cliente.
  // (La barrera dura debe estar también en la policy del bucket en Supabase.)
  MAX_BYTES: 5 * 1024 * 1024,
  ALLOWED_TYPES: ['image/jpeg', 'image/png', 'image/webp'],
  EXT_BY_TYPE: { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' },

  // Marca de agua: se superpone el logo con opacidad en la esquina inferior
  // derecha. El logo original es 612x408 (ratio 1.5). Se redimensiona al 18%
  // del ancho de la foto y se separa del borde un 3%. La imagen resultante se
  // exporta (JPG/WebP con calidad ~.85, PNG se conserva) para que el público
  // solo vea la versión marcada.
  WATERMARK_SRC: '/img/logo_final.png',
  WATERMARK_SCALE: 0.18,
  WATERMARK_MARGIN: 0.03,
  WATERMARK_ALPHA: 0.55,
  WATERMARK_QUALITY: 0.85,

  async uploadPhoto(escortId, file) {
    if (!this.ALLOWED_TYPES.includes(file.type)) {
      throw new Error('Formato no permitido. Usá JPG, PNG o WebP.');
    }
    if (file.size > this.MAX_BYTES) {
      throw new Error('La imagen supera los 5MB.');
    }

    // Plazo duro: procesar la marca puede agrandar la imagen (canvas exporta
    // en el mejor formato disponible). Si supera el tope se rechaza.
    const blob = await this.processWithWatermark(file);
    if (blob.size > this.MAX_BYTES) {
      throw new Error('La imagen con marca de agua supera los 5MB. Probá con una de menor peso.');
    }

    // La extensión sale del MIME real del blob (el watermark re-exporta todo
    // lo que no es PNG como JPEG), no del archivo original.
    const ext = this.EXT_BY_TYPE[blob.type] || 'jpg';
    const fileName = `${escortId}/${Date.now()}.${ext}`;

    const { error: uploadError } = await window.supabaseClient
      .storage
      .from('escort-photos')
      .upload(fileName, blob, { contentType: blob.type, upsert: false });

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

  // Carga la foto, superpone el logo y devuelve el Blob resultante ya marcado.
  async processWithWatermark(file) {
    const dataUrl = await this._readAsDataURL(file);
    const img = await this._loadImage(dataUrl);

    const canvas = document.createElement('canvas');
    const W = img.naturalWidth || img.width;
    const H = img.naturalHeight || img.height;
    canvas.width = W;
    canvas.height = H;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0, W, H);

    // Logo con opacidad en la esquina inferior derecha.
    try {
      const logo = await this._loadImage(this.WATERMARK_SRC);
      const logoW = Math.round(W * this.WATERMARK_SCALE);
      const logoH = Math.round(logoW / (logo.naturalWidth / logo.naturalHeight));
      const padX = Math.round(W * this.WATERMARK_MARGIN);
      const padY = Math.round(H * this.WATERMARK_MARGIN);
      ctx.globalAlpha = this.WATERMARK_ALPHA;
      ctx.drawImage(logo, W - logoW - padX, H - logoH - padY, logoW, logoH);
      ctx.globalAlpha = 1;
    } catch {
      // Si el logo no carga, se sube la foto sin marca en lugar de romper el
      // flujo de subida.
    }

    // Export: PNG mantiene transparencia; JPG/WebP usan calidad ~.85.
    const mime = file.type === 'image/png' ? 'image/png' : 'image/jpeg';
    const q = mime === 'image/png' ? undefined : this.WATERMARK_QUALITY;
    return new Promise((resolve, reject) => {
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('No se pudo generar la imagen con marca.'))), mime, q);
    });
  },

  _readAsDataURL(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(new Error('No se pudo leer la imagen.'));
      reader.readAsDataURL(file);
    });
  },

  _loadImage(src) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error('No se pudo cargar la imagen.'));
      img.src = src;
    });
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
