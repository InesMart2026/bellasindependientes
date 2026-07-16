window.authHelpers = {
  // Registro con email + contraseña. Sin confirmación de email: la identidad
  // real se prueba con el KYC (DNI + selfie), no con un link al correo. Así se
  // evita el problema del navegador interno de Gmail en el celular.
  async signUp(email, password) {
    const { error } = await window.supabaseClient.auth.signUp({ email, password });
    if (error) throw error;
  },

  // Ingreso de una cuenta ya creada.
  async signIn(email, password) {
    const { error } = await window.supabaseClient.auth.signInWithPassword({ email, password });
    if (error) throw error;
  },

  // Recuperar contraseña: manda un link para fijar una nueva.
  async resetPassword(email) {
    const { error } = await window.supabaseClient.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/dashboard/nueva-clave.html`,
    });
    if (error) throw error;
  },

  async logout() {
    await window.supabaseClient.auth.signOut();
    window.location.href = '/dashboard/login.html';
  },

  getSession() {
    return window.supabaseClient.auth.getSession();
  },

  async getUser() {
    const { data: { user } } = await window.supabaseClient.auth.getUser();
    return user;
  },

  async requireAuth() {
    // getSession() lee de localStorage sin validar: puede devolver una sesión
    // con el access_token vencido. Con ese token muerto, las RPC salen anónimas
    // (auth.uid() = null) y get_my_profile() devuelve vacío → rebotaba a
    // verificación a una escort verificada. getUser() sí valida contra el server
    // y refresca el token si el refresh_token todavía sirve.
    const { data: { session } } = await this.getSession();
    if (!session) {
      window.location.href = '/dashboard/login.html';
      return null;
    }

    const { data: { user }, error } = await window.supabaseClient.auth.getUser();
    if (error || !user) {
      // Token no recuperable: se limpia la sesión muerta y se manda a login,
      // en vez de dejar pasar con un JWT que hará fallar toda llamada posterior.
      await window.supabaseClient.auth.signOut().catch(() => {});
      window.location.href = '/dashboard/login.html';
      return null;
    }
    return user;
  }
};
