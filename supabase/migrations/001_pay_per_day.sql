-- Migración: modelo pay-per-day con paquetes (MercadoPago)
-- Reemplaza el modelo plans/subscriptions por visibilidad por vencimiento.
-- Correr en el SQL Editor de Supabase DESPUÉS de schema.sql.

-- ─────────────────────────────────────────────────────────────
-- 1. Vencimiento del slot en escorts
-- ─────────────────────────────────────────────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS visible_hasta TIMESTAMPTZ;

-- El grid público solo muestra perfiles pagos y vigentes.
-- Reemplazamos la policy de SELECT para exigir visible_hasta vigente.
DROP POLICY IF EXISTS "escorts_select_public" ON escorts;
CREATE POLICY "escorts_select_public" ON escorts
  FOR SELECT USING (
    (activa = true AND visible_hasta IS NOT NULL AND visible_hasta >= now())
    OR auth.uid() = user_id
  );

-- Índice para ordenar el grid rápido (destacada primero, luego vencimiento)
CREATE INDEX IF NOT EXISTS idx_escorts_grid
  ON escorts (categoria, destacada DESC, visible_hasta DESC)
  WHERE activa = true;

-- ─────────────────────────────────────────────────────────────
-- 2. Paquetes de días (con descuento por volumen)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS packages (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nombre TEXT NOT NULL,
  dias INTEGER NOT NULL,
  precio_total NUMERIC NOT NULL,   -- lo que paga la escort, en ARS
  precio_dia NUMERIC NOT NULL,     -- solo informativo para mostrar el ahorro
  destacada BOOLEAN DEFAULT false, -- true = el slot compra posición destacada
  orden INTEGER DEFAULT 0,
  activo BOOLEAN DEFAULT true
);

ALTER TABLE packages ENABLE ROW LEVEL SECURITY;

-- Los paquetes son públicos (la página de precios los lista sin login)
DROP POLICY IF EXISTS "packages_select_public" ON packages;
CREATE POLICY "packages_select_public" ON packages
  FOR SELECT USING (activo = true);

-- ─────────────────────────────────────────────────────────────
-- 3. Pagos (registro de cada compra vía MercadoPago)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pagos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  package_id UUID REFERENCES packages(id) NOT NULL,
  monto NUMERIC NOT NULL,
  dias INTEGER NOT NULL,
  mp_preference_id TEXT,          -- id de la preferencia de Checkout Pro
  mp_payment_id TEXT,             -- id del pago confirmado por el webhook
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'approved', 'rejected', 'cancelled')),
  created_at TIMESTAMPTZ DEFAULT now(),
  approved_at TIMESTAMPTZ
);

ALTER TABLE pagos ENABLE ROW LEVEL SECURITY;

-- La escort ve solo sus propios pagos
DROP POLICY IF EXISTS "pagos_select_own" ON pagos;
CREATE POLICY "pagos_select_own" ON pagos
  FOR SELECT USING (
    auth.uid() = (SELECT user_id FROM escorts WHERE id = pagos.escort_id)
  );

-- La escort puede crear un pago pendiente para su propio perfil.
-- La aprobación NUNCA la hace ella: la hace el webhook (service_role).
DROP POLICY IF EXISTS "pagos_insert_own" ON pagos;
CREATE POLICY "pagos_insert_own" ON pagos
  FOR INSERT WITH CHECK (
    auth.uid() = (SELECT user_id FROM escorts WHERE id = pagos.escort_id)
    AND status = 'pending'
  );

-- ─────────────────────────────────────────────────────────────
-- 4. Activación del slot — SOLO invocable por el webhook (service_role)
--    Nunca desde el navegador. Extiende visible_hasta y prende activa.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION activate_slot(pago_id UUID, mp_payment TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  p RECORD;
  base TIMESTAMPTZ;
BEGIN
  SELECT * INTO p FROM pagos WHERE id = pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pago no encontrado'; END IF;
  IF p.status = 'approved' THEN RETURN; END IF; -- idempotente

  -- Si el slot sigue vigente, sumamos días desde el vencimiento actual.
  -- Si ya venció (o nunca pagó), contamos desde ahora.
  SELECT GREATEST(COALESCE(visible_hasta, now()), now())
    INTO base FROM escorts WHERE id = p.escort_id;

  UPDATE escorts
    SET activa = true,
        visible_hasta = base + (p.dias || ' days')::interval,
        destacada = destacada OR (SELECT destacada FROM packages WHERE id = p.package_id)
    WHERE id = p.escort_id;

  UPDATE pagos
    SET status = 'approved', mp_payment_id = mp_payment, approved_at = now()
    WHERE id = pago_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 5. Actualizar funciones de perfil para exponer visible_hasta
--    Se borran primero: no se puede cambiar el tipo de salida con REPLACE.
-- ─────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_profile();
DROP FUNCTION IF EXISTS get_escort_decrypted(TEXT);

CREATE OR REPLACE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ,
              created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  key TEXT;
  uid UUID;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN RETURN; END IF;

  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

CREATE OR REPLACE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ,
              created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at
  FROM escorts e
  WHERE e.slug = slug_param
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;
