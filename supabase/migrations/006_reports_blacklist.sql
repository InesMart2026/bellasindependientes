-- ═══════════════════════════════════════════════════════════════════
-- 006 — Denuncias de perfiles + bloqueo + lista negra por DNI
--
-- Objetivo:
--  · Cualquier visitante (sin cuenta) puede denunciar un perfil indicando
--    su email, una categoría y el motivo. La denuncia NO bloquea sola:
--    un abuso de denuncias tumbaría perfiles legítimos. El bloqueo es una
--    ACCIÓN ADMIN posterior, tomada tras revisar la denuncia.
--  · Cuando la administración confirma una infracción grave (CSAM, trata,
--    multicuenta, suplantación, etc.) bloquea el perfil y opcionalmente
--    suma el DNI a una lista negra. Al bloquear, la escort se despublica.
--  · La lista negra guarda un HASH del DNI (SHA-256), nunca el DNI plano:
--    alcanza para vetar un re-registro sin almacenar el documento
--    (minimización de datos, Ley 25.326 de Protección de Datos Personales).
--
-- Marco legal (Argentina):
--  · Ley 26.842 (trata de personas) y Ley 27.436 (tenencia de material de
--    abuso sexual infantil) → categorías de denuncia prioritarias.
--  · Art. 1710 CCyC (deber de prevención del daño) → habilita despublicar
--    ante indicios, sin auto-bloqueo automático que dañe a un tercero.
--  · Ley 25.326 → hash en lugar de DNI plano; retención mínima.
-- ═══════════════════════════════════════════════════════════════════

-- pgcrypto ya está instalada (la migración 004 encripta con pgp_sym_*),
-- pero está en el schema `extensions`, fuera del search_path por defecto
-- de las migraciones y de las funciones. pgp_sym_* resolvía por suerte del
-- contexto, pero digest() no. Las funciones que usan pgcrypto abajo fijan
-- `SET search_path = public, extensions` en su definición para que resuelva
-- en tiempo de ejecución sin importar quién las llame.

-- ── 1. Columnas de bloqueo en escorts ──────────────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS bloqueada        BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS bloqueada_motivo TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS bloqueada_at     TIMESTAMPTZ;

-- ── 2. Congelar las columnas de bloqueo para el rol authenticated ──
-- La escort no puede desbloquearse sola desde la consola del navegador.
-- Se extiende el guard existente (migración 004) sumando las 3 columnas.
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
  NEW.bloqueada           := OLD.bloqueada;
  NEW.bloqueada_motivo    := OLD.bloqueada_motivo;
  NEW.bloqueada_at        := OLD.bloqueada_at;
  RETURN NEW;
END;
$$;

-- ── 3. Un perfil bloqueado nunca es visible públicamente ───────────
-- Se recrea la RPC pública sumando la condición bloqueada = false.
-- (El dueño tampoco lo verá activo, pero podrá saber que fue bloqueado
--  vía get_my_profile, que exponemos abajo.)
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
    AND e.bloqueada = false
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;

-- ── 4. Tabla de denuncias ──────────────────────────────────────────
-- Categorías alineadas al marco legal argentino. 'menores' y 'trata' son
-- las de máxima prioridad (delitos penales, revisión inmediata).
CREATE TABLE IF NOT EXISTS reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escort_id  UUID REFERENCES escorts(id) ON DELETE SET NULL,
  slug       TEXT,                         -- se guarda el slug por si se borra el perfil
  categoria  TEXT NOT NULL CHECK (categoria IN (
                'menores',        -- material de abuso sexual infantil / menor en fotos
                'trata',          -- indicios de trata o explotación (Ley 26.842)
                'multicuenta',    -- misma persona con varias cuentas
                'suplantacion',   -- fotos/identidad de otra persona sin consentimiento
                'contenido',      -- contenido prohibido o fuera de las políticas
                'estafa',         -- fraude / extorsión / datos falsos
                'otro'
              )),
  email      TEXT NOT NULL,                 -- contacto del denunciante (obligatorio)
  motivo     TEXT NOT NULL,                 -- descripción libre del hecho
  estado     TEXT NOT NULL DEFAULT 'nueva'
                CHECK (estado IN ('nueva','en_revision','resuelta','descartada')),
  ip_hash    TEXT,                          -- hash de IP para rate-limit, no la IP
  created_at TIMESTAMPTZ DEFAULT now(),
  resolved_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS reports_escort_idx ON reports (escort_id);
CREATE INDEX IF NOT EXISTS reports_estado_idx ON reports (estado);

ALTER TABLE reports ENABLE ROW LEVEL SECURITY;

-- Nadie (ni anon ni authenticated) puede leer denuncias: contienen datos
-- de terceros. Solo service_role (admin/Edge Functions) las consulta.
-- No se crea policy de SELECT → queda cerrado por defecto.
-- El INSERT tampoco se abre directo: se canaliza por la RPC submit_report,
-- que valida y aplica rate-limit. Sin policy de INSERT para authenticated/anon.

-- ── 5. RPC pública para enviar una denuncia ────────────────────────
-- SECURITY DEFINER: corre con privilegios del owner, así puede insertar
-- en reports aunque el rol anon no tenga policy de INSERT. Valida los
-- datos y aplica un rate-limit blando por hash de email + slug.
CREATE OR REPLACE FUNCTION submit_report(
  slug_param  TEXT,
  categoria_param TEXT,
  email_param TEXT,
  motivo_param TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  eid UUID;
  recientes INT;
BEGIN
  -- Validaciones mínimas (defensa en profundidad; el cliente ya valida).
  IF categoria_param NOT IN ('menores','trata','multicuenta','suplantacion','contenido','estafa','otro') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'categoria invalida');
  END IF;
  IF email_param IS NULL OR email_param !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email invalido');
  END IF;
  IF motivo_param IS NULL OR length(trim(motivo_param)) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'motivo demasiado corto');
  END IF;
  IF length(motivo_param) > 4000 THEN
    motivo_param := left(motivo_param, 4000);
  END IF;

  -- Resolver el perfil denunciado (puede no existir: se guarda igual con slug).
  SELECT id INTO eid FROM escorts WHERE slug = slug_param;

  -- Rate-limit: máximo 3 denuncias del mismo email al mismo slug por hora.
  SELECT count(*) INTO recientes
  FROM reports
  WHERE email = lower(email_param)
    AND slug = slug_param
    AND created_at > now() - interval '1 hour';

  IF recientes >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'demasiadas denuncias, intenta mas tarde');
  END IF;

  INSERT INTO reports (escort_id, slug, categoria, email, motivo)
  VALUES (eid, slug_param, categoria_param, lower(email_param), trim(motivo_param));

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- anon y authenticated pueden ejecutar la RPC (no la tabla directamente).
GRANT EXECUTE ON FUNCTION submit_report(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ── 6. Lista negra por hash de DNI ─────────────────────────────────
CREATE TABLE IF NOT EXISTS blacklist (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  dni_hash   TEXT UNIQUE NOT NULL,          -- SHA-256 del DNI normalizado
  motivo     TEXT NOT NULL,
  report_id  UUID REFERENCES reports(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE blacklist ENABLE ROW LEVEL SECURITY;
-- Sin policies → solo service_role puede leer/escribir. El chequeo en el
-- registro se hace vía RPC SECURITY DEFINER (is_dni_blacklisted).

-- Normaliza un DNI (solo dígitos) y devuelve su hash SHA-256 en hex.
CREATE OR REPLACE FUNCTION dni_hash(dni_raw TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE
SET search_path = public, extensions AS $$
  SELECT encode(digest(regexp_replace(coalesce(dni_raw,''), '\\D', '', 'g'), 'sha256'), 'hex');
$$;

-- ¿Este DNI está vetado? Devuelve boolean sin exponer la lista.
-- La usa el gate de registro (Edge Function) con el DNI que la persona
-- ingresa al verificarse.
CREATE OR REPLACE FUNCTION is_dni_blacklisted(dni_raw TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN EXISTS (SELECT 1 FROM blacklist WHERE dni_hash = dni_hash(dni_raw));
END;
$$;

-- ¿El DNI ya guardado (encriptado) de una escort está vetado? Desencripta
-- internamente y compara por hash, sin que el DNI plano viaje por la red.
-- La usa el gate de registro/verificación (Edge Function crear-kyc).
CREATE OR REPLACE FUNCTION is_dni_blacklisted_for_escort(escort_id_param UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  key TEXT;
  dni_plano TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';
  SELECT CASE WHEN dni ~ '\\x' THEN pgp_sym_decrypt(dni::bytea, key) ELSE dni END
    INTO dni_plano
    FROM escorts WHERE id = escort_id_param;

  IF dni_plano IS NULL OR length(regexp_replace(dni_plano, '\\D', '', 'g')) = 0 THEN
    RETURN false;
  END IF;

  RETURN EXISTS (SELECT 1 FROM blacklist WHERE dni_hash = dni_hash(dni_plano));
END;
$$;

-- ── 7. RPC de acción admin: bloquear perfil + (opcional) lista negra ──
-- La invoca la Edge Function admin-bloquear con service_role. Bloquea el
-- perfil, lo despublica, y si se pide, agrega el DNI a la lista negra
-- tomándolo directamente de la fila (desencriptado con la enc_key).
CREATE OR REPLACE FUNCTION block_and_blacklist(
  escort_id_param UUID,
  motivo_param    TEXT,
  add_to_blacklist BOOLEAN DEFAULT true,
  report_id_param UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  key TEXT;
  dni_plano TEXT;
BEGIN
  -- Solo service_role puede bloquear.
  IF coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autorizado');
  END IF;

  UPDATE escorts
     SET bloqueada = true,
         bloqueada_motivo = motivo_param,
         bloqueada_at = now(),
         activa = false
   WHERE id = escort_id_param;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'perfil inexistente');
  END IF;

  IF add_to_blacklist THEN
    SELECT value INTO key FROM secrets WHERE name = 'enc_key';
    SELECT CASE WHEN dni ~ '\\x' THEN pgp_sym_decrypt(dni::bytea, key) ELSE dni END
      INTO dni_plano
      FROM escorts WHERE id = escort_id_param;

    IF dni_plano IS NOT NULL AND length(regexp_replace(dni_plano, '\\D', '', 'g')) > 0 THEN
      INSERT INTO blacklist (dni_hash, motivo, report_id)
      VALUES (dni_hash(dni_plano), motivo_param, report_id_param)
      ON CONFLICT (dni_hash) DO NOTHING;
    END IF;
  END IF;

  IF report_id_param IS NOT NULL THEN
    UPDATE reports SET estado = 'resuelta', resolved_at = now()
     WHERE id = report_id_param;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── 7b. RPC de acción admin: descartar una denuncia sin bloquear ───
-- Cuando la administración revisa y NO se comprueba la infracción.
CREATE OR REPLACE FUNCTION dismiss_report(report_id_param UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autorizado');
  END IF;

  UPDATE reports SET estado = 'descartada', resolved_at = now()
   WHERE id = report_id_param;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'denuncia inexistente');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── 8. Exponer el estado de bloqueo al dueño en get_my_profile ─────
-- Para que el dashboard pueda mostrar "tu perfil fue bloqueado".
DROP FUNCTION IF EXISTS get_my_profile();
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT,
              provincia TEXT, localidad TEXT, acuerdo_legal BOOLEAN,
              estado_verificacion TEXT, bloqueada BOOLEAN, bloqueada_motivo TEXT)
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
         e.provincia, e.localidad, e.acuerdo_legal, e.estado_verificacion,
         e.bloqueada, e.bloqueada_motivo
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;
