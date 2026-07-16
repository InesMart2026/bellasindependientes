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
    const { data: { session } } = await this.getSession();
    if (!session) {
      window.location.href = '/dashboard/login.html';
      return null;
    }
    return session.user;
  }
};
