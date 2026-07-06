-- ═══════════════════════════════════════════════════════════════════
-- 004 — Datos legales de la escort + verificación de identidad (KYC Didit)
--
-- Modelo:
--  · Datos personales sensibles (nombre real, apellido, dirección, DNI,
--    celular) se guardan ENCRIPTADOS con el mismo esquema pgcrypto ya
--    existente (secrets.enc_key + trigger). La escort nunca ve los de otra.
--  · Provincia/localidad y el acuerdo legal van en texto plano (no sensibles).
--  · La verificación biométrica (selfie vs DNI + liveness) la hace Didit.
--    Nosotros NO almacenamos imágenes de documentos: solo el veredicto.
--  · estado_verificacion lo prende SOLO el webhook de Didit vía RPC
--    activate_verification (SECURITY DEFINER), nunca el navegador.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Columnas nuevas en escorts ──────────────────────────────────
-- Sensibles (se encriptan vía trigger):
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS nombre_real TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS apellido    TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS direccion   TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS dni         TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS celular     TEXT;

-- No sensibles:
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS provincia TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS localidad TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS acuerdo_legal BOOLEAN DEFAULT false;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS acuerdo_legal_at TIMESTAMPTZ;

-- Estado de verificación: pendiente → en_revision → verificado | rechazado
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS estado_verificacion TEXT
  NOT NULL DEFAULT 'pendiente'
  CHECK (estado_verificacion IN ('pendiente','en_revision','verificado','rechazado'));

-- ── 2. Extender el trigger de encriptación a los datos personales ──
-- Reescribe la función existente sumando los 5 campos nuevos.
CREATE OR REPLACE FUNCTION auto_encrypt_sensitive() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  IF NEW.instagram   IS NOT NULL AND NEW.instagram   !~ '\\x' THEN NEW.instagram   = pgp_sym_encrypt(NEW.instagram, key);   END IF;
  IF NEW.whatsapp    IS NOT NULL AND NEW.whatsapp    !~ '\\x' THEN NEW.whatsapp    = pgp_sym_encrypt(NEW.whatsapp, key);    END IF;
  IF NEW.nombre_real IS NOT NULL AND NEW.nombre_real !~ '\\x' THEN NEW.nombre_real = pgp_sym_encrypt(NEW.nombre_real, key); END IF;
  IF NEW.apellido    IS NOT NULL AND NEW.apellido    !~ '\\x' THEN NEW.apellido    = pgp_sym_encrypt(NEW.apellido, key);    END IF;
  IF NEW.direccion   IS NOT NULL AND NEW.direccion   !~ '\\x' THEN NEW.direccion   = pgp_sym_encrypt(NEW.direccion, key);   END IF;
  IF NEW.dni         IS NOT NULL AND NEW.dni         !~ '\\x' THEN NEW.dni         = pgp_sym_encrypt(NEW.dni, key);         END IF;
  IF NEW.celular     IS NOT NULL AND NEW.celular     !~ '\\x' THEN NEW.celular     = pgp_sym_encrypt(NEW.celular, key);     END IF;

  RETURN NEW;
END;
$$;

-- El trigger original solo escuchaba UPDATE OF instagram, whatsapp.
-- Recrearlo para que también dispare al tocar los campos nuevos.
DROP TRIGGER IF EXISTS encrypt_sensitive_trigger ON escorts;
CREATE TRIGGER encrypt_sensitive_trigger
  BEFORE INSERT OR UPDATE OF instagram, whatsapp, nombre_real, apellido, direccion, dni, celular
  ON escorts
  FOR EACH ROW EXECUTE FUNCTION auto_encrypt_sensitive();

-- ── 3. Registro de sesiones KYC de Didit ───────────────────────────
CREATE TABLE IF NOT EXISTS kyc_verifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  didit_session_id TEXT UNIQUE,
  status TEXT NOT NULL DEFAULT 'created'
    CHECK (status IN ('created','pending','approved','declined','abandoned')),
  score NUMERIC,
  raw JSONB,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS kyc_escort_idx ON kyc_verifications (escort_id);

ALTER TABLE kyc_verifications ENABLE ROW LEVEL SECURITY;

-- La escort puede ver el estado de SUS verificaciones (no las de otras).
-- No expone datos biométricos: los documentos viven en Didit, no acá.
DROP POLICY IF EXISTS "kyc_select_own" ON kyc_verifications;
CREATE POLICY "kyc_select_own" ON kyc_verifications
  FOR SELECT USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = escort_id));

-- INSERT/UPDATE solo por service_role (Edge Functions). Sin policy para
-- authenticated → el navegador no puede escribir acá. service_role bypassa RLS.

-- ── 4. RPC: estado de verificación para el dashboard ───────────────
-- La escort consulta en qué anda su KYC sin ver documentos.
DROP FUNCTION IF EXISTS get_my_verification_status();
CREATE FUNCTION get_my_verification_status()
RETURNS TABLE(estado TEXT, kyc_status TEXT, updated_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  uid UUID;
  eid UUID;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN RETURN; END IF;

  SELECT id INTO eid FROM escorts WHERE user_id = uid;
  IF eid IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT e.estado_verificacion,
         k.status,
         COALESCE(k.updated_at, e.acuerdo_legal_at)
  FROM escorts e
  LEFT JOIN LATERAL (
    SELECT status, updated_at FROM kyc_verifications
    WHERE escort_id = e.id ORDER BY created_at DESC LIMIT 1
  ) k ON true
  WHERE e.id = eid;
END;
$$;

-- ── 5. RPC: aplicar veredicto de Didit (SOLO webhook) ──────────────
-- Idempotente. La llama el webhook-kyc con service_role.
CREATE OR REPLACE FUNCTION activate_verification(
  session_id TEXT,
  new_status TEXT,
  new_score  NUMERIC,
  payload    JSONB
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  eid UUID;
BEGIN
  UPDATE kyc_verifications
    SET status = new_status,
        score = new_score,
        raw = payload,
        updated_at = now()
  WHERE didit_session_id = session_id
  RETURNING escort_id INTO eid;

  IF eid IS NULL THEN RETURN; END IF;

  -- Mapear el resultado de Didit al estado de la escort.
  UPDATE escorts SET estado_verificacion =
    CASE
      WHEN new_status = 'approved' THEN 'verificado'
      WHEN new_status = 'declined' THEN 'rechazado'
      ELSE 'en_revision'
    END
  WHERE id = eid;
END;
$$;

-- ── 6. Actualizar RPCs de perfil para exponer estado_verificacion ──
-- Se agregan las columnas legales NO sensibles y el estado. Los datos
-- encriptados (nombre_real, dni, etc.) NO se exponen por estas RPC:
-- son de acceso admin únicamente.
DROP FUNCTION IF EXISTS get_my_profile();
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT,
              provincia TEXT, localidad TEXT, acuerdo_legal BOOLEAN,
              estado_verificacion TEXT)
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
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello, e.servicios, e.idiomas,
         e.provincia, e.localidad, e.acuerdo_legal, e.estado_verificacion
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

-- ── 7. Blindaje: la escort no puede auto-verificarse ni auto-activarse ──
-- La RLS escorts_update_own deja actualizar toda la fila. Sin esto, desde
-- la consola del navegador podría hacer:
--   update escorts set estado_verificacion='verificado', activa=true ...
-- y saltear KYC y pago. Este trigger congela las columnas críticas para
-- el rol authenticated; solo service_role (webhooks) puede cambiarlas.
CREATE OR REPLACE FUNCTION guard_protected_columns() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- service_role bypassa RLS y corre con otro rol → se le permite todo.
  IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' THEN
    RETURN NEW;
  END IF;

  NEW.estado_verificacion := OLD.estado_verificacion;
  NEW.activa              := OLD.activa;
  NEW.visible_hasta       := OLD.visible_hasta;
  NEW.destacada           := OLD.destacada;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_protected_columns_trigger ON escorts;
CREATE TRIGGER guard_protected_columns_trigger
  BEFORE UPDATE ON escorts
  FOR EACH ROW EXECUTE FUNCTION guard_protected_columns();

-- Perfil público: sin cambios de columnas (no expone datos legales).
-- Se recrea solo para mantener la firma alineada con la migración 003.
DROP FUNCTION IF EXISTS get_escort_decrypted(TEXT);
CREATE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello, e.servicios, e.idiomas
  FROM escorts e
  WHERE e.slug = slug_param
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;
