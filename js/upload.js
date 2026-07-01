window.uploadHelpers = {
  async uploadPhoto(escortId, file) {
    const ext = file.name.split('.').pop();
    const fileName = `${escortId}/${Date.now()}.${ext}`;

    const { error: uploadError } = await window.supabaseClient
      .storage
      .from('escort-photos')
      .upload(fileName, file);

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
