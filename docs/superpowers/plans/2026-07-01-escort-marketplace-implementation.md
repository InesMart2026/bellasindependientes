# Escort Marketplace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a vanilla HTML/CSS/JS + Supabase marketplace where escorts publish profiles and photos across categories (Mujeres, Hombres, Trans), with a dashboard for content management.

**Architecture:** Static site served from Netlify, Supabase as backend (Auth, Storage, PostgreSQL + RLS). No build step. No server. Pages load data from Supabase via JS SDK.

**Tech Stack:** HTML5, CSS3, JavaScript (vanilla ES6+), Supabase JS SDK v2, Supabase Storage.

## Global Constraints

- No build tools, no npm, no frameworks
- All config in a single Supabase project
- RLS on every table
- Dark Luxury visual theme (negro #000-#111, dorado #D4AF37, cards #1A1A1A)
- Playfair Display (títulos), Inter (cuerpo)
- Mercado Pago para pagos (Fase 2)
- Mobile-first responsive

---

### Task 1: Project scaffolding + Supabase schema

**Files:**
- Create: `supabase/schema.sql`
- Create: `supabase/seed.sql`
- Create: `js/supabase.js`
- Create: favicon placeholder

**Interfaces:**
- Consumes: nothing
- Produces: `supabaseClient` global (window.supabaseClient), DB tables + RLS policies

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p ecr/css ecr/js ecr/dashboard ecr/supabase ecr/img ecr/docs/superpowers/plans
```

- [ ] **Step 2: Write schema.sql**

```sql
-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Escorts table
CREATE TABLE escorts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  nombre TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  categoria TEXT NOT NULL CHECK (categoria IN ('mujeres', 'hombres', 'trans')),
  edad INTEGER,
  ubicacion TEXT,
  bio TEXT,
  instagram TEXT,
  whatsapp TEXT,
  activa BOOLEAN DEFAULT false,
  destacada BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Photos table
CREATE TABLE photos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  url TEXT NOT NULL,
  orden INTEGER DEFAULT 0,
  es_portada BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Plans table
CREATE TABLE plans (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nombre TEXT NOT NULL,
  precio NUMERIC NOT NULL,
  duracion_dias INTEGER NOT NULL,
  max_fotos INTEGER NOT NULL
);

-- Subscriptions table
CREATE TABLE subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  plan_id UUID REFERENCES plans(id) NOT NULL,
  inicio DATE DEFAULT CURRENT_DATE,
  fin DATE NOT NULL,
  paga BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- RLS: Escorts
ALTER TABLE escorts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "escorts_select_public" ON escorts
  FOR SELECT USING (activa = true OR auth.uid() = user_id);

CREATE POLICY "escorts_insert_own" ON escorts
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "escorts_update_own" ON escorts
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "escorts_delete_own" ON escorts
  FOR DELETE USING (auth.uid() = user_id);

-- RLS: Photos
ALTER TABLE photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "photos_select_public" ON photos
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM escorts WHERE escorts.id = photos.escort_id AND escorts.activa = true)
    OR auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id)
  );

CREATE POLICY "photos_insert_own" ON photos
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id));

CREATE POLICY "photos_delete_own" ON photos
  FOR DELETE USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id));

-- RLS: Subscriptions
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "subscriptions_select_own" ON subscriptions
  FOR SELECT USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = subscriptions.escort_id));

CREATE POLICY "subscriptions_insert_own" ON subscriptions
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM escorts WHERE id = subscriptions.escort_id));

-- Storage bucket for photos
INSERT INTO storage.buckets (id, name, public) VALUES ('escort-photos', 'escort-photos', true);
```

- [ ] **Step 3: Write seed.sql**

```sql
INSERT INTO plans (nombre, precio, duracion_dias, max_fotos) VALUES
  ('Básico', 5000, 30, 5),
  ('Premium', 10000, 30, 15);
```

- [ ] **Step 4: Write js/supabase.js**

```javascript
const SUPABASE_URL = 'https://tu-proyecto.supabase.co';
const SUPABASE_ANON_KEY = 'tu-anon-key';

const { createClient } = supabase;
window.supabaseClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
```

- [ ] **Step 5: Create .gitignore**

```
.env
node_modules/
.DS_Store
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: add supabase schema and project scaffolding"
```

---

### Task 2: Core CSS — Dark Luxury theme

**Files:**
- Create: `css/style.css`
- Create: `css/dashboard.css`

**Interfaces:**
- Consumes: nothing
- Produces: global styles consumed by all pages

- [ ] **Step 1: Write css/style.css (global + public pages)**

```css
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600&family=Playfair+Display:wght@400;600;700&display=swap');

:root {
  --bg-primary: #000;
  --bg-secondary: #111;
  --bg-card: #1A1A1A;
  --gold: #D4AF37;
  --gold-light: #F5E6A3;
  --text-primary: #FAFAFA;
  --text-secondary: #888;
  --border: #2A2A2A;
  --font-display: 'Playfair Display', serif;
  --font-body: 'Inter', sans-serif;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: var(--font-body);
  background: var(--bg-primary);
  color: var(--text-primary);
  min-height: 100vh;
}

a { color: var(--gold); text-decoration: none; }
a:hover { color: var(--gold-light); }

/* Header */
.header {
  position: sticky; top: 0; z-index: 100;
  background: rgba(0,0,0,.95);
  border-bottom: 1px solid var(--border);
  padding: 1rem 2rem;
  display: flex; justify-content: space-between; align-items: center;
}

.header-logo {
  font-family: var(--font-display);
  font-size: 1.5rem; font-weight: 700;
  color: var(--gold);
  text-transform: uppercase;
  letter-spacing: 3px;
}

.header-nav { display: flex; gap: 2rem; align-items: center; }
.header-nav a { color: var(--text-secondary); font-size: .9rem; text-transform: uppercase; letter-spacing: 1px; }
.header-nav a:hover { color: var(--gold); }

/* Hero */
.hero {
  display: grid;
  grid-template-columns: 2fr 1fr;
  grid-template-rows: 300px 300px;
  gap: 4px;
  height: 604px;
  overflow: hidden;
}

.hero-item {
  position: relative;
  overflow: hidden;
  cursor: pointer;
}

.hero-item img { width: 100%; height: 100%; object-fit: cover; }
.hero-item:first-child { grid-row: 1 / 3; }

.hero-overlay {
  position: absolute; inset: 0;
  background: linear-gradient(to top, rgba(0,0,0,.8) 0%, transparent 60%);
  display: flex; flex-direction: column; justify-content: flex-end;
  padding: 2rem;
}

.hero-overlay h1 {
  font-family: var(--font-display);
  font-size: 3rem; font-weight: 700;
  line-height: 1.1;
}

/* Section titles */
.section-title {
  font-family: var(--font-display);
  font-size: 2rem;
  padding: 3rem 2rem 1.5rem;
  text-align: center;
}

/* Grid */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  gap: 1.5rem;
  padding: 0 2rem 3rem;
}

/* Card */
.card {
  position: relative;
  background: var(--bg-card);
  border-radius: 4px;
  overflow: hidden;
  transition: transform .3s ease, box-shadow .3s ease;
  cursor: pointer;
}

.card:hover {
  transform: translateY(-4px);
  box-shadow: 0 8px 30px rgba(212, 175, 55, .15);
}

.card-img {
  width: 100%;
  aspect-ratio: 3 / 4;
  object-fit: cover;
  display: block;
}

.card-body {
  position: absolute;
  bottom: 0; left: 0; right: 0;
  padding: 1.5rem 1rem 1rem;
  background: linear-gradient(to top, rgba(0,0,0,.9) 0%, transparent 100%);
}

.card-body h3 { font-size: 1.1rem; font-weight: 600; }
.card-body p { color: var(--text-secondary); font-size: .85rem; margin-top: .25rem; }

.card-badge {
  position: absolute; top: 1rem; right: 1rem;
  background: var(--gold); color: #000;
  padding: .25rem .75rem;
  font-size: .75rem; font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 1px;
  border-radius: 2px;
}

/* Categories nav */
.categories-nav {
  display: flex; justify-content: center; gap: 1rem;
  padding: 2rem;
}

.cat-btn {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-secondary);
  padding: .75rem 2rem;
  font-family: var(--font-body);
  font-size: .9rem;
  text-transform: uppercase;
  letter-spacing: 1px;
  cursor: pointer;
  transition: all .3s;
}

.cat-btn:hover, .cat-btn.active {
  border-color: var(--gold);
  color: var(--gold);
}

/* Profile page */
.profile-hero {
  position: relative;
  height: 50vh;
  min-height: 400px;
  overflow: hidden;
}

.profile-hero img { width: 100%; height: 100%; object-fit: cover; }

.profile-info {
  position: absolute;
  bottom: 0; left: 0; right: 0;
  padding: 3rem 2rem 2rem;
  background: linear-gradient(to top, #000 0%, transparent 100%);
}

.profile-info h1 {
  font-family: var(--font-display);
  font-size: 2.5rem;
}

.profile-meta { color: var(--text-secondary); margin-top: .5rem; display: flex; gap: 1rem; }

.profile-content {
  max-width: 1200px;
  margin: 0 auto;
  padding: 2rem;
  display: grid;
  grid-template-columns: 1fr 2fr;
  gap: 2rem;
}

.profile-bio p { color: var(--text-secondary); line-height: 1.7; margin-top: 1rem; }

.profile-social { display: flex; gap: 1rem; margin-top: 1.5rem; }
.profile-social a {
  padding: .5rem 1.5rem;
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-size: .85rem;
  transition: all .3s;
}
.profile-social a:hover { border-color: var(--gold); color: var(--gold); }

/* Gallery */
.gallery-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: 1rem;
}

.gallery-grid img {
  width: 100%; aspect-ratio: 3/4; object-fit: cover;
  cursor: pointer;
  transition: opacity .3s;
}
.gallery-grid img:hover { opacity: .8; }

/* Lightbox */
.lightbox {
  display: none;
  position: fixed; inset: 0; z-index: 999;
  background: rgba(0,0,0,.95);
  justify-content: center; align-items: center;
}

.lightbox.active { display: flex; }

.lightbox img {
  max-width: 90vw;
  max-height: 90vh;
  object-fit: contain;
}

.lightbox-close {
  position: absolute; top: 1rem; right: 1rem;
  background: none; border: none;
  color: var(--text-primary);
  font-size: 2rem; cursor: pointer;
}

/* Footer */
.footer {
  border-top: 1px solid var(--border);
  padding: 2rem;
  text-align: center;
  color: var(--text-secondary);
  font-size: .85rem;
}

/* Responsive */
@media (max-width: 768px) {
  .hero { grid-template-columns: 1fr; grid-template-rows: 200px 150px 150px; height: auto; }
  .hero-item:first-child { grid-row: auto; }
  .hero-overlay h1 { font-size: 2rem; }
  .header { padding: 1rem; flex-direction: column; gap: 1rem; }
  .header-nav { gap: 1rem; flex-wrap: wrap; justify-content: center; }
  .profile-content { grid-template-columns: 1fr; }
  .grid { grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); padding: 0 1rem 2rem; gap: 1rem; }
}
```

- [ ] **Step 2: Write css/dashboard.css**

```css
.dashboard-layout {
  display: grid;
  grid-template-columns: 250px 1fr;
  min-height: 100vh;
}

.dashboard-sidebar {
  background: var(--bg-secondary);
  border-right: 1px solid var(--border);
  padding: 2rem 0;
}

.dashboard-sidebar .header-logo {
  padding: 0 1.5rem 2rem;
  border-bottom: 1px solid var(--border);
  margin-bottom: 1rem;
}

.dashboard-nav { list-style: none; }

.dashboard-nav li a {
  display: flex; align-items: center; gap: .75rem;
  padding: .75rem 1.5rem;
  color: var(--text-secondary);
  transition: all .2s;
  font-size: .9rem;
}

.dashboard-nav li a:hover,
.dashboard-nav li a.active {
  background: rgba(212, 175, 55, .1);
  color: var(--gold);
  border-right: 2px solid var(--gold);
}

.dashboard-main { padding: 2rem; }

.dashboard-header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 2rem;
}

.dashboard-header h2 {
  font-family: var(--font-display);
  font-size: 1.5rem;
}

/* Upload area */
.upload-area {
  border: 2px dashed var(--border);
  border-radius: 4px;
  padding: 3rem;
  text-align: center;
  cursor: pointer;
  transition: all .3s;
  margin-bottom: 2rem;
}

.upload-area:hover { border-color: var(--gold); background: rgba(212,175,55,.05); }

.upload-area input { display: none; }
.upload-area p { color: var(--text-secondary); margin-top: .5rem; }

/* Form */
.form-group { margin-bottom: 1.5rem; }

.form-group label {
  display: block;
  color: var(--text-secondary);
  font-size: .85rem;
  text-transform: uppercase;
  letter-spacing: 1px;
  margin-bottom: .5rem;
}

.form-group input,
.form-group textarea,
.form-group select {
  width: 100%;
  padding: .75rem 1rem;
  background: var(--bg-card);
  border: 1px solid var(--border);
  color: var(--text-primary);
  font-family: var(--font-body);
  font-size: .95rem;
  border-radius: 4px;
}

.form-group textarea { min-height: 100px; resize: vertical; }

.btn {
  padding: .75rem 2rem;
  border: none;
  font-family: var(--font-body);
  font-size: .9rem;
  text-transform: uppercase;
  letter-spacing: 1px;
  cursor: pointer;
  transition: all .3s;
}

.btn-gold { background: var(--gold); color: #000; }
.btn-gold:hover { background: var(--gold-light); }

.btn-outline {
  background: transparent;
  border: 1px solid var(--border);
  color: var(--text-primary);
}
.btn-outline:hover { border-color: var(--gold); color: var(--gold); }

/* Dashboard gallery */
.dash-gallery {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 1rem;
}

.dash-gallery-item {
  position: relative;
  aspect-ratio: 3/4;
  overflow: hidden;
  border-radius: 4px;
}

.dash-gallery-item img { width: 100%; height: 100%; object-fit: cover; }

.dash-gallery-item .delete-btn {
  position: absolute; top: .5rem; right: .5rem;
  background: rgba(255,0,0,.8);
  color: white; border: none;
  width: 28px; height: 28px;
  border-radius: 50%;
  cursor: pointer;
  font-size: .8rem;
  opacity: 0;
  transition: opacity .3s;
}

.dash-gallery-item:hover .delete-btn { opacity: 1; }

/* Plan card */
.plan-card {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 2rem;
  text-align: center;
  max-width: 350px;
}

.plan-card h3 { font-family: var(--font-display); font-size: 1.3rem; }
.plan-price { font-size: 2rem; color: var(--gold); margin: 1rem 0; font-weight: 700; }
.plan-features { list-style: none; color: var(--text-secondary); margin-bottom: 1.5rem; }
.plan-features li { padding: .5rem 0; border-bottom: 1px solid var(--border); }

/* Tablet / mobile */
@media (max-width: 768px) {
  .dashboard-layout { grid-template-columns: 1fr; }
  .dashboard-sidebar { display: none; }
  .dashboard-mobile-nav { display: flex; }
}
```

- [ ] **Step 3: Commit**

```bash
git add css/ && git commit -m "feat: add Dark Luxury CSS theme"
```

---

### Task 3: JavaScript core — Supabase client + auth

**Files:**
- Create: `js/supabase.js`
- Create: `js/auth.js`

**Interfaces:**
- Consumes: nothing
- Produces: `window.supabaseClient`, `window.authHelpers` (login, logout, getSession, getUser)

- [ ] **Step 1: Write js/supabase.js**

Load Supabase JS SDK from CDN:

```html
<!-- in each page's <head> -->
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="/js/supabase.js"></script>
```

```javascript
// js/supabase.js
const SUPABASE_URL = window.SUPABASE_URL || 'https://YOUR_PROJECT.supabase.co';
const SUPABASE_ANON_KEY = window.SUPABASE_ANON_KEY || 'YOUR_ANON_KEY';

window.supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
```

- [ ] **Step 2: Write js/auth.js**

```javascript
// js/auth.js
const authHelpers = {
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
```

- [ ] **Step 3: Commit**

```bash
git add js/supabase.js js/auth.js && git commit -m "feat: add supabase client and auth helpers"
```

---

### Task 4: JavaScript — Gallery + lightbox + Supabase queries

**Files:**
- Create: `js/gallery.js`
- Create: `js/upload.js`

**Interfaces:**
- Consumes: `window.supabaseClient`
- Produces: `window.galleryHelpers`, `window.uploadHelpers`

- [ ] **Step 1: Write js/gallery.js**

```javascript
// js/gallery.js
const galleryHelpers = {
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
      .from('escorts')
      .select('*')
      .eq('slug', slug)
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
        <h3>${escort.nombre}, ${escort.edad || ''}</h3>
        <p>${escort.ubicacion || ''}</p>
      </div>
    `;
    return div;
  },

  renderPhotoGrid(photos, containerId) {
    const container = document.getElementById(containerId);
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
    const img = lb.querySelector('img');
    img.src = url;
    lb.classList.add('active');
  },

  closeLightbox() {
    document.getElementById('lightbox').classList.remove('active');
  }
};
```

- [ ] **Step 2: Write js/upload.js**

```javascript
// js/upload.js
const uploadHelpers = {
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
```

- [ ] **Step 3: Add lightbox HTML to base pages (inline)**

```html
<div id="lightbox" class="lightbox">
  <button class="lightbox-close" onclick="galleryHelpers.closeLightbox()">×</button>
  <img src="" alt="Foto">
</div>
```

- [ ] **Step 4: Commit**

```bash
git add js/gallery.js js/upload.js && git commit -m "feat: add gallery and upload helpers"
```

---

### Task 5: Home page (index.html)

**Files:**
- Create: `index.html`

**Interfaces:**
- Consumes: `galleryHelpers`
- Produces: landing page

- [ ] **Step 1: Write index.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ECR — Escorts</title>
  <link rel="stylesheet" href="/css/style.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/gallery.js" defer></script>
</head>
<body>
  <header class="header">
    <a href="/" class="header-logo">ECR</a>
    <nav class="header-nav">
      <a href="/mujeres.html">Mujeres</a>
      <a href="/hombres.html">Hombres</a>
      <a href="/trans.html">Trans</a>
      <a href="/planes.html">Planes</a>
      <a href="/dashboard/login.html">Acceder</a>
    </nav>
  </header>

  <section class="hero" id="hero">
    <div class="hero-item">
      <img src="https://images.unsplash.com/photo-1529626455594-4ff0802cfb7e?w=800" alt="" loading="lazy">
      <div class="hero-overlay">
        <h1>Encontrá la compañía perfecta</h1>
      </div>
    </div>
    <div class="hero-item">
      <img src="https://images.unsplash.com/photo-1504257432389-52343af06ae3?w=400" alt="" loading="lazy">
    </div>
    <div class="hero-item">
      <img src="https://images.unsplash.com/photo-1519699047748-de8e457a634e?w=400" alt="" loading="lazy">
    </div>
  </section>

  <nav class="categories-nav">
    <a href="/mujeres.html" class="cat-btn">Mujeres</a>
    <a href="/hombres.html" class="cat-btn">Hombres</a>
    <a href="/trans.html" class="cat-btn">Trans</a>
  </nav>

  <h2 class="section-title">Destacadas</h2>
  <div class="grid" id="escorts-grid"></div>

  <div id="lightbox" class="lightbox">
    <button class="lightbox-close" onclick="galleryHelpers.closeLightbox()">×</button>
    <img src="" alt="Foto">
  </div>

  <footer class="footer">
    <p>ECR &copy; 2026 &mdash; Todos los derechos reservados</p>
  </footer>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      try {
        const escorts = await galleryHelpers.fetchEscorts();
        const grid = document.getElementById('escorts-grid');

        for (const escort of escorts.slice(0, 8)) {
          const portada = await galleryHelpers.fetchPortada(escort.id);
          grid.appendChild(galleryHelpers.renderCard(escort, portada.url));
        }
      } catch (err) {
        console.error('Error loading escorts:', err);
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add index.html && git commit -m "feat: add home page"
```

---

### Task 6: Category pages

**Files:**
- Create: `mujeres.html`
- Create: `hombres.html`
- Create: `trans.html`

**Interfaces:**
- Consumes: `galleryHelpers`
- Produces: category listing pages

- [ ] **Step 1: Write mujeres.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mujeres — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/gallery.js" defer></script>
</head>
<body>
  <header class="header">[same header as index]</header>

  <h2 class="section-title">Mujeres</h2>
  <div class="grid" id="escorts-grid"></div>

  <div id="lightbox" class="lightbox">[same lightbox]</div>
  <footer class="footer">[same footer]</footer>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      try {
        const escorts = await galleryHelpers.fetchEscorts('mujeres');
        const grid = document.getElementById('escorts-grid');
        for (const escort of escorts) {
          const portada = await galleryHelpers.fetchPortada(escort.id);
          grid.appendChild(galleryHelpers.renderCard(escort, portada.url));
        }
      } catch (err) { console.error(err); }
    });
  </script>
</body>
</html>
```

Repeat for `hombres.html` (categoria: 'hombres') and `trans.html` (categoria: 'trans'), changing only the title and the category parameter.

- [ ] **Step 2: Create hombres.html and trans.html** (same template, swap category value and title)
- [ ] **Step 3: Commit**

```bash
git add mujeres.html hombres.html trans.html && git commit -m "feat: add category pages"
```

---

### Task 7: Profile page (perfil.html)

**Files:**
- Create: `perfil.html`

**Interfaces:**
- Consumes: `galleryHelpers`
- Produces: individual escort profile page

- [ ] **Step 1: Write perfil.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Perfil — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/gallery.js" defer></script>
</head>
<body>
  <header class="header">[same header]</header>

  <div id="profile-container"></div>

  <div id="lightbox" class="lightbox">
    <button class="lightbox-close" onclick="galleryHelpers.closeLightbox()">×</button>
    <img src="" alt="Foto">
  </div>

  <footer class="footer">[same footer]</footer>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const params = new URLSearchParams(window.location.search);
      const slug = params.get('slug');

      if (!slug) {
        document.getElementById('profile-container').innerHTML = '<p style="padding:2rem;color:#888;">Perfil no encontrado</p>';
        return;
      }

      try {
        const escort = await galleryHelpers.fetchEscortBySlug(slug);
        const photos = await galleryHelpers.fetchPhotos(escort.id);
        const portada = photos.find(p => p.es_portada) || photos[0];

        const container = document.getElementById('profile-container');

        let socialHtml = '';
        if (escort.instagram) socialHtml += `<a href="https://instagram.com/${escort.instagram}" target="_blank">Instagram</a>`;
        if (escort.whatsapp) socialHtml += `<a href="https://wa.me/${escort.whatsapp}" target="_blank">WhatsApp</a>`;

        container.innerHTML = `
          <div class="profile-hero">
            <img src="${portada?.url || 'https://via.placeholder.com/1200x600?text=Sin+foto'}" alt="${escort.nombre}">
            <div class="profile-info">
              <h1>${escort.nombre}, ${escort.edad || ''}</h1>
              <div class="profile-meta">
                <span>${escort.categoria}</span>
                ${escort.ubicacion ? `<span>${escort.ubicacion}</span>` : ''}
              </div>
            </div>
          </div>

          <div class="profile-content">
            <div>
              <h3>Sobre mí</h3>
              <div class="profile-bio">
                <p>${escort.bio || 'Sin descripción'}</p>
              </div>
              <div class="profile-social">${socialHtml || '<p style="color:#888;">Sin redes</p>'}</div>
            </div>

            <div>
              <h3>Galería</h3>
              <div class="gallery-grid" id="gallery-grid"></div>
            </div>
          </div>
        `;

        galleryHelpers.renderPhotoGrid(photos, 'gallery-grid');
      } catch (err) {
        document.getElementById('profile-container').innerHTML = '<p style="padding:2rem;color:#888;">Perfil no encontrado</p>';
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add perfil.html && git commit -m "feat: add escort profile page"
```

---

### Task 8: Plans page (planes.html)

**Files:**
- Create: `planes.html`

**Interfaces:**
- Consumes: `window.supabaseClient`
- Produces: plans listing with subscription CTA

- [ ] **Step 1: Write planes.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Planes — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js" defer></script>
</head>
<body>
  <header class="header">[same header]</header>

  <h2 class="section-title">Planes de Suscripción</h2>
  <p style="text-align:center;color:#888;max-width:600px;margin:0 auto 2rem;">
    Publicá tu perfil y llegá a más clientes. Elegí el plan que mejor se adapte a vos.
  </p>

  <div style="display:flex;justify-content:center;gap:2rem;padding:0 2rem 3rem;flex-wrap:wrap;" id="plans-container">
    <!-- loaded from Supabase -->
  </div>

  <footer class="footer">[same footer]</footer>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const { data: plans, error } = await window.supabaseClient
        .from('plans')
        .select('*')
        .order('precio', { ascending: true });

      if (error) return;

      const container = document.getElementById('plans-container');
      plans.forEach(plan => {
        container.innerHTML += `
          <div class="plan-card">
            <h3>${plan.nombre}</h3>
            <div class="plan-price">$${plan.precio.toLocaleString('es-AR')}</div>
            <ul class="plan-features">
              <li>${plan.duracion_dias} días de publicación</li>
              <li>Hasta ${plan.max_fotos} fotos</li>
            </ul>
            <a href="/dashboard/login.html" class="btn btn-gold">Contratar</a>
          </div>
        `;
      });
    });
  </script>
</body>
</html>
```

Add `.plan-card` styles are already in dashboard.css. Add minimal inline styles or add them to style.css:

- [ ] **Step 2: Add plan-card styles to style.css** (copy from dashboard.css or link dashboard.css on this page)
- [ ] **Step 3: Commit**

```bash
git add planes.html && git commit -m "feat: add plans page"
```

---

### Task 9: Dashboard login page

**Files:**
- Create: `dashboard/login.html`

**Interfaces:**
- Consumes: `authHelpers`
- Produces: login/register with magic link

- [ ] **Step 1: Write dashboard/login.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Acceder — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <link rel="stylesheet" href="/css/dashboard.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/auth.js" defer></script>
</head>
<body style="display:flex;justify-content:center;align-items:center;min-height:100vh;">
  <div style="max-width:400px;width:100%;padding:2rem;">
    <a href="/" class="header-logo" style="display:block;text-align:center;margin-bottom:2rem;">ECR</a>
    <h2 style="text-align:center;margin-bottom:.5rem;">Accedé a tu panel</h2>
    <p style="text-align:center;color:var(--text-secondary);margin-bottom:2rem;">Te enviamos un link mágico a tu email</p>

    <div id="message" style="display:none;padding:1rem;margin-bottom:1rem;border-radius:4px;"></div>

    <form id="login-form">
      <div class="form-group">
        <label>Email</label>
        <input type="email" id="email" required placeholder="tu@email.com">
      </div>
      <button type="submit" class="btn btn-gold" style="width:100%;">Enviar link mágico</button>
    </form>

    <p style="text-align:center;margin-top:2rem;color:var(--text-secondary);font-size:.85rem;">
      ¿No tenés cuenta? <a href="/planes.html">Elegí un plan</a>
    </p>
  </div>

  <script>
    document.getElementById('login-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      const email = document.getElementById('email').value;
      const btn = e.target.querySelector('button');
      btn.disabled = true;
      btn.textContent = 'Enviando...';

      try {
        await authHelpers.login(email);
        showMessage('Link mágico enviado. Revisá tu email.', 'success');
      } catch (err) {
        showMessage('Error: ' + err.message, 'error');
      }

      btn.disabled = false;
      btn.textContent = 'Enviar link mágico';
    });

    function showMessage(text, type) {
      const msg = document.getElementById('message');
      msg.style.display = 'block';
      msg.textContent = text;
      msg.style.background = type === 'success' ? 'rgba(212,175,55,.1)' : 'rgba(255,0,0,.1)';
      msg.style.color = type === 'success' ? 'var(--gold)' : '#ff4444';
    }
  </script>
</body>
</html>
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/login.html && git commit -m "feat: add dashboard login page"
```

---

### Task 10: Dashboard — main panel + profile editing + photo management

**Files:**
- Create: `dashboard/index.html`
- Create: `dashboard/fotos.html`
- Create: `dashboard/perfil.html`
- Create: `dashboard/plan.html`

**Interfaces:**
- Consumes: `authHelpers`, `galleryHelpers`, `uploadHelpers`
- Produces: full dashboard

- [ ] **Step 1: Write dashboard/index.html (includes sidebar + layout)**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Dashboard — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <link rel="stylesheet" href="/css/dashboard.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/auth.js"></script>
  <script src="/js/gallery.js"></script>
  <script src="/js/upload.js"></script>
</head>
<body>
  <div class="dashboard-layout">
    <aside class="dashboard-sidebar">
      <a href="/dashboard/" class="header-logo">ECR</a>
      <ul class="dashboard-nav">
        <li><a href="/dashboard/" class="active">Panel</a></li>
        <li><a href="/dashboard/fotos.html">Mis Fotos</a></li>
        <li><a href="/dashboard/perfil.html">Mi Perfil</a></li>
        <li><a href="/dashboard/plan.html">Mi Plan</a></li>
        <li><a href="#" onclick="authHelpers.logout()">Cerrar sesión</a></li>
      </ul>
    </aside>

    <main class="dashboard-main">
      <div class="dashboard-header">
        <h2>Panel de Control</h2>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;" id="stats">
        <div class="plan-card" style="text-align:left;">
          <p style="color:var(--text-secondary);font-size:.85rem;">Fotos subidas</p>
          <p style="font-size:2rem;color:var(--gold);font-weight:700;" id="photo-count">—</p>
        </div>
        <div class="plan-card" style="text-align:left;">
          <p style="color:var(--text-secondary);font-size:.85rem;">Plan actual</p>
          <p style="font-size:1.2rem;" id="current-plan">—</p>
        </div>
      </div>
    </main>
  </div>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const user = await authHelpers.requireAuth();
      if (!user) return;

      const { data: escort } = await window.supabaseClient
        .from('escorts')
        .select('*')
        .eq('user_id', user.id)
        .single();

      if (!escort) {
        // Escort hasn't created profile yet — redirect to profile editor
        window.location.href = '/dashboard/perfil.html';
        return;
      }

      const { count } = await window.supabaseClient
        .from('photos')
        .select('*', { count: 'exact', head: true })
        .eq('escort_id', escort.id);

      document.getElementById('photo-count').textContent = count || 0;

      const { data: sub } = await window.supabaseClient
        .from('subscriptions')
        .select('*, plans(*)')
        .eq('escort_id', escort.id)
        .gte('fin', new Date().toISOString().split('T')[0])
        .maybeSingle();

      document.getElementById('current-plan').textContent = sub ? sub.plans.nombre : 'Sin plan activo';
    });
  </script>
</body>
</html>
```

- [ ] **Step 2: Write dashboard/perfil.html** (profile creation/editing)

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mi Perfil — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <link rel="stylesheet" href="/css/dashboard.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/auth.js" defer></script>
</head>
<body>
  <div class="dashboard-layout">
    <aside class="dashboard-sidebar">[same sidebar]</aside>

    <main class="dashboard-main">
      <div class="dashboard-header">
        <h2>Mi Perfil</h2>
      </div>

      <form id="profile-form" style="max-width:600px;">
        <div class="form-group">
          <label>Nombre público</label>
          <input type="text" id="nombre" required placeholder="Ej: Sofía">
        </div>

        <div class="form-group">
          <label>Slug (URL de tu perfil)</label>
          <input type="text" id="slug" required placeholder="ej: sofia">
        </div>

        <div class="form-group">
          <label>Categoría</label>
          <select id="categoria">
            <option value="mujeres">Mujeres</option>
            <option value="hombres">Hombres</option>
            <option value="trans">Trans</option>
          </select>
        </div>

        <div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem;">
          <div class="form-group">
            <label>Edad</label>
            <input type="number" id="edad" min="18" max="99">
          </div>
          <div class="form-group">
            <label>Ubicación</label>
            <input type="text" id="ubicacion" placeholder="Ej: Buenos Aires">
          </div>
        </div>

        <div class="form-group">
          <label>Sobre vos</label>
          <textarea id="bio" maxlength="500"></textarea>
        </div>

        <div style="display:grid;grid-template-columns:1fr 1fr;gap:1rem;">
          <div class="form-group">
            <label>Instagram (opcional)</label>
            <input type="text" id="instagram" placeholder="@usuario">
          </div>
          <div class="form-group">
            <label>WhatsApp (opcional)</label>
            <input type="text" id="whatsapp" placeholder="5491112345678">
          </div>
        </div>

        <button type="submit" class="btn btn-gold">Guardar</button>
      </form>
    </main>
  </div>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const user = await authHelpers.requireAuth();
      if (!user) return;

      const { data: escort } = await window.supabaseClient
        .from('escorts')
        .select('*')
        .eq('user_id', user.id)
        .maybeSingle();

      if (escort) {
        document.getElementById('nombre').value = escort.nombre || '';
        document.getElementById('slug').value = escort.slug || '';
        document.getElementById('categoria').value = escort.categoria || 'mujeres';
        document.getElementById('edad').value = escort.edad || '';
        document.getElementById('ubicacion').value = escort.ubicacion || '';
        document.getElementById('bio').value = escort.bio || '';
        document.getElementById('instagram').value = escort.instagram || '';
        document.getElementById('whatsapp').value = escort.whatsapp || '';
      }

      document.getElementById('profile-form').addEventListener('submit', async (e) => {
        e.preventDefault();

        const formData = {
          nombre: document.getElementById('nombre').value,
          slug: document.getElementById('slug').value,
          categoria: document.getElementById('categoria').value,
          edad: parseInt(document.getElementById('edad').value) || null,
          ubicacion: document.getElementById('ubicacion').value,
          bio: document.getElementById('bio').value,
          instagram: document.getElementById('instagram').value,
          whatsapp: document.getElementById('whatsapp').value,
          user_id: user.id
        };

        if (escort) {
          await window.supabaseClient.from('escorts').update(formData).eq('id', escort.id);
        } else {
          await window.supabaseClient.from('escorts').insert(formData);
        }

        alert('Perfil guardado correctamente');
        window.location.href = '/dashboard/';
      });
    });
  </script>
</body>
</html>
```

- [ ] **Step 3: Write dashboard/fotos.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mis Fotos — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <link rel="stylesheet" href="/css/dashboard.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/auth.js"></script>
  <script src="/js/gallery.js"></script>
  <script src="/js/upload.js" defer></script>
</head>
<body>
  <div class="dashboard-layout">
    <aside class="dashboard-sidebar">[same sidebar]</aside>

    <main class="dashboard-main">
      <div class="dashboard-header">
        <h2>Mis Fotos</h2>
      </div>

      <div class="upload-area" id="upload-area">
        <p style="font-size:2rem;color:var(--gold);">+</p>
        <p>Hacé click o arrastrá fotos acá</p>
        <p style="font-size:.8rem;">JPG, PNG, WebP — Máx 5MB</p>
        <input type="file" id="file-input" accept="image/*" multiple>
      </div>

      <div class="dash-gallery" id="photos-grid"></div>
    </main>
  </div>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const user = await authHelpers.requireAuth();
      if (!user) return;

      const { data: escort } = await window.supabaseClient
        .from('escorts')
        .select('id')
        .eq('user_id', user.id)
        .single();

      if (!escort) { window.location.href = '/dashboard/perfil.html'; return; }

      async function loadPhotos() {
        const photos = await galleryHelpers.fetchPhotos(escort.id);
        const grid = document.getElementById('photos-grid');
        grid.innerHTML = '';

        photos.forEach(photo => {
          const item = document.createElement('div');
          item.className = 'dash-gallery-item';
          item.innerHTML = `
            <img src="${photo.url}" loading="lazy">
            <button class="delete-btn" data-id="${photo.id}">×</button>
          `;
          grid.appendChild(item);
        });

        grid.querySelectorAll('.delete-btn').forEach(btn => {
          btn.addEventListener('click', async () => {
            if (!confirm('¿Eliminar esta foto?')) return;
            await uploadHelpers.deletePhoto(btn.dataset.id);
            loadPhotos();
          });
        });
      }

      // Upload
      document.getElementById('upload-area').addEventListener('click', () => {
        document.getElementById('file-input').click();
      });

      document.getElementById('file-input').addEventListener('change', async (e) => {
        for (const file of e.target.files) {
          await uploadHelpers.uploadPhoto(escort.id, file);
        }
        loadPhotos();
      });

      // Drag & drop on upload area
      const area = document.getElementById('upload-area');
      area.addEventListener('dragover', (e) => { e.preventDefault(); area.style.borderColor = 'var(--gold)'; });
      area.addEventListener('dragleave', () => { area.style.borderColor = ''; });
      area.addEventListener('drop', async (e) => {
        e.preventDefault();
        area.style.borderColor = '';
        for (const file of e.dataTransfer.files) {
          if (file.type.startsWith('image/')) {
            await uploadHelpers.uploadPhoto(escort.id, file);
          }
        }
        loadPhotos();
      });

      await loadPhotos();
    });
  </script>
</body>
</html>
```

- [ ] **Step 4: Write dashboard/plan.html**

```html
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Mi Plan — ECR</title>
  <link rel="stylesheet" href="/css/style.css">
  <link rel="stylesheet" href="/css/dashboard.css">
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
  <script src="/js/supabase.js"></script>
  <script src="/js/auth.js" defer></script>
</head>
<body>
  <div class="dashboard-layout">
    <aside class="dashboard-sidebar">[same sidebar]</aside>

    <main class="dashboard-main">
      <div class="dashboard-header">
        <h2>Mi Plan</h2>
      </div>

      <div id="plan-status"></div>
      <div id="plans-offer" style="display:flex;gap:2rem;flex-wrap:wrap;margin-top:2rem;"></div>
    </main>
  </div>

  <script>
    document.addEventListener('DOMContentLoaded', async () => {
      const user = await authHelpers.requireAuth();
      if (!user) return;

      const { data: escort } = await window.supabaseClient
        .from('escorts')
        .select('id')
        .eq('user_id', user.id)
        .single();

      if (!escort) { window.location.href = '/dashboard/perfil.html'; return; }

      const { data: sub } = await window.supabaseClient
        .from('subscriptions')
        .select('*, plans(*)')
        .eq('escort_id', escort.id)
        .gte('fin', new Date().toISOString().split('T')[0])
        .maybeSingle();

      const statusDiv = document.getElementById('plan-status');
      if (sub && sub.paga) {
        statusDiv.innerHTML = `
          <div class="plan-card" style="text-align:left;">
            <h3>${sub.plans.nombre}</h3>
            <p style="color:var(--gold);margin:.5rem 0;">✓ Activo</p>
            <p style="color:var(--text-secondary);font-size:.85rem;">
              Vigente hasta: ${new Date(sub.fin).toLocaleDateString('es-AR')}
            </p>
          </div>
        `;
      } else {
        statusDiv.innerHTML = '<p style="color:var(--text-secondary);">No tenés un plan activo. Elegí uno para publicar tu perfil.</p>';

        const { data: plans } = await window.supabaseClient.from('plans').select('*').order('precio');
        const offerDiv = document.getElementById('plans-offer');
        plans.forEach(plan => {
          offerDiv.innerHTML += `
            <div class="plan-card">
              <h3>${plan.nombre}</h3>
              <div class="plan-price">$${plan.precio.toLocaleString('es-AR')}</div>
              <ul class="plan-features">
                <li>${plan.duracion_dias} días</li>
                <li>Hasta ${plan.max_fotos} fotos</li>
              </ul>
              <button class="btn btn-gold" onclick="alert('Mercado Pago próximamente. Contactanos para activar tu plan.')">Contratar</button>
            </div>
          `;
        });
      }
    });
  </script>
</body>
</html>
```

- [ ] **Step 5: Commit**

```bash
git add dashboard/ && git commit -m "feat: add dashboard pages"
```

---

### Task 11: Final wiring — shared header/footer template note + Supabase config

**Files:**
- Modify: all .html files (ensure consistency)
- Create: `js/config.js` (centralized Supabase config)
- Readme note about setup

- [ ] **Step 1: Create js/config.js** (optional externalized config — or keep in supabase.js)

If using a config file:

```javascript
// js/config.js
window.SUPABASE_URL = 'https://tu-proyecto.supabase.co';
window.SUPABASE_ANON_KEY = 'tu-anon-key';
```

Loaded before supabase.js in every page.

- [ ] **Step 2: Add README note in index.html** (or separate setup doc)

Not needed — the schema.sql and seed.sql serve as setup documentation.

- [ ] **Step 3: Final commit**

```bash
git add -A && git commit -m "chore: final wiring and cleanup"
```
