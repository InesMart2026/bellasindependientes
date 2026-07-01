# Especificación: Marketplace de Escorts

## Resumen

Plataforma web donde escorts publican su perfil y fotos, organizadas en categorías (Mujeres, Hombres, Trans). Las escorts pagan una suscripción para mantener su perfil activo. Los clientes navegan gratis.

## Stack

- **Frontend:** HTML, CSS, JavaScript vanilla
- **Backend:** Supabase (Auth, Storage, PostgreSQL + RLS)
- **Hosting:** Netlify o Vercel (gratis)
- **Pagos:** Mercado Pago (Argentina)
- **Tipografía:** Playfair Display (títulos), Inter (cuerpo)

## Dirección Visual

**Dark Luxury** — fondos oscuros, dorados, tipografía serif elegante.

- Background: `#000` a `#111`
- Acentos: `#D4AF37`, `#F5E6A3`
- Cards: `#1A1A1A` con bordes sutiles
- Texto: `#FAFAFA`, body: `#888`

## Modelo de Datos

### `escorts`
| Columna | Tipo | Descripción |
|---|---|---|
| id | uuid PK | |
| user_id | uuid FK -> auth.users | Usuario de Supabase Auth |
| nombre | text | Nombre público |
| slug | text unique | Para URL /escort/:slug |
| categoria | text | 'mujeres' | 'hombres' | 'trans' |
| edad | int | |
| ubicacion | text | Ciudad |
| bio | text | Descripción |
| instagram | text | Opcional |
| whatsapp | text | Opcional |
| activa | boolean | Solo activa si tiene suscripción vigente |
| destacada | boolean | Para home |
| created_at | timestamptz | |

### `photos`
| Columna | Tipo | Descripción |
|---|---|---|
| id | uuid PK | |
| escort_id | uuid FK -> escorts | |
| url | text | URL de Supabase Storage |
| orden | int | Para ordenar en galería |
| es_portada | boolean | Foto principal en cards |
| created_at | timestamptz | |

### `plans`
| Columna | Tipo | Descripción |
|---|---|---|
| id | uuid PK | |
| nombre | text | Ej: "Básico", "Premium" |
| precio | numeric | ARS |
| duracion_dias | int | |
| max_fotos | int | ||

### `subscriptions`
| Columna | Tipo | Descripción |
|---|---|---|
| id | uuid PK | |
| escort_id | uuid FK -> escorts | |
| plan_id | uuid FK -> plans | |
| inicio | date | |
| fin | date | |
| paga | boolean | Confirmado pago |

### RLS (Row Level Security)
- `escorts`: SELECT público si activa=true; INSERT/UPDATE/DELETE solo si auth.uid() = user_id
- `photos`: SELECT público JOIN con escort activa; INSERT/UPDATE/DELETE solo si auth.uid() = dueño de la escort
- `subscriptions`: solo lectura/escritura para el dueño de la escort

## Estructura de Archivos

```
ecr/
├── index.html              # Home
├── mujeres.html             # Categoría mujeres
├── hombres.html             # Categoría hombres
├── trans.html               # Categoría trans
├── planes.html              # Planes de suscripción
├── perfil.html              # Perfil individual (carga dinámica por slug)
├── dashboard/
│   ├── login.html           # Login / registro
│   ├── index.html           # Panel principal (resumen)
│   ├── fotos.html           # Gestión de fotos
│   ├── perfil.html          # Editar perfil
│   └── plan.html            # Ver / contratar plan
├── css/
│   ├── style.css            # Estilos globales
│   └── dashboard.css        # Estilos del panel
├── js/
│   ├── supabase.js          # Cliente Supabase + init
│   ├── auth.js              # Login / registro / session
│   ├── gallery.js           # Render de galerías y cards
│   ├── dashboard.js         # Lógica del panel de control
│   └── upload.js            # Subida de fotos a Storage
├── supabase/
│   └── schema.sql           # SQL para crear tablas + RLS
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-07-01-escort-marketplace-design.md
```

## Páginas

### Home (`/`)
- Hero con grid asimétrico de fotos destacadas (3-4 imágenes grandes)
- Nav: Logo | Mujeres | Hombres | Trans | Planes | Acceder
- Sección "Destacadas" con cards horizontales
- Footer: links legales, contacto, copyright

### Categoría (`/mujeres`, `/hombres`, `/trans`)
- Título de sección
- Filtros: edad, ubicación
- Grid 3-4 columnas de cards
- Paginación (cargar más)

### Card de Escort
- Foto portada (3:4, object-fit: cover)
- Overlay con nombre + edad + ubicación
- Badge de categoría
- Link a `/perfil.html?slug=nombre`

### Perfil (`/perfil.html?slug=...`)
- Hero con foto de portada grande
- Info: nombre, edad, ubicación, bio
- Redes sociales (Instagram, WhatsApp) con íconos
- Galería de fotos en grid 2-3 columnas
- Lightbox al click en foto

### Planes (`/planes.html`)
- Tabla comparativa de planes (Básico / Premium)
- Precio, duración, cantidad de fotos
- Botón "Contratar" (redirige a Mercado Pago)

### Dashboard
- **Login** — email + magic link (Supabase Auth)
- **Resumen** — estado del plan, fotos subidas, perfil
- **Mis Fotos** — grilla con miniaturas, botón subir (file input), eliminar
- **Mi Perfil** — formulario para editar nombre, bio, ubicación, redes
- **Mi Plan** — ver plan actual, contratar/renovar

## Componentes

### Header
- Logo (texto estilizado "ECR" o nombre)
- Navegación inline
- Estado de sesión (si está logueado, mostrar "Dashboard")
- Sticky on scroll

### Hero
- Grid CSS de fotos asimétrico
- Overlay oscuro gradiente
- Título grande superpuesto

### Gallery Grid
- CSS Grid responsive con auto-fill
- Aspect-ratio 3:4
- Hover: scale sutil + overlay info
- Lightbox en perfil

### Dashboard Sidebar
- Iconos + texto
- Pestañas navegables
- Cerrar sesión al final

## Flujo de Pago (MVP)

1. Escort elige plan en `/planes.html` o `/dashboard/plan.html`
2. Click → redirige a checkout de Mercado Pago
3. Mercado Pago confirma pago vía webhook
4. Supabase actualiza `subscriptions.paga = true`
5. Escort activa su perfil (o se activa automático)

Para MVP inicial, se puede hacer **manual**: la escort paga por transferencia, el admin activa manualmente desde Supabase.

## Priorización MVP

### Fase 1 — Core
- Home, categorías, perfil individual
- Login + dashboard básico (subir fotos con file input simple, editar perfil)
- Schema + RLS en Supabase
- Hosting en Netlify
- Activación manual de perfiles (admin desde Supabase)

### Fase 2 — Pagos
- Integración Mercado Pago
- Activación automática de perfiles al pagar
- Página de planes

### Fase 3 — Mejoras
- Búsqueda y filtros
- Drag & drop en dashboard
- Infinite scroll
- Sección "Destacadas" dinámica
