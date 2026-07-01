window.authHelpers = {
  async login(email) {
    const { error } = await window.supabaseClient.auth.signInWithOtp({ email });
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
