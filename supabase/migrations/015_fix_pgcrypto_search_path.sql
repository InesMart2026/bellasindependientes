-- ── Fix: get_my_profile / get_escort_decrypted no encontraban pgp_sym_decrypt
--
-- La migración 006 ya había resuelto esto: pgcrypto vive en el schema
-- `extensions` (default de Supabase), fuera del search_path. Sus funciones
-- deben declarar `SET search_path = public, extensions` para resolver
-- pgp_sym_decrypt / pgp_sym_encrypt.
--
-- La 010 redefinió estas dos funciones copiando el patrón viejo con
-- `SET search_path = public` a secas → perdió `extensions`. Resultado:
-- la RPC lanzaba `function pgp_sym_decrypt(bytea, text) does not exist`
-- SIEMPRE que el SELECT tocaba instagram/whatsapp. Desde el frontend eso
-- se veía como "perfil vacío" y rebotaba a verificación a una escort ya
-- verificada. Recién saltó cuando la primera escort verificada llegó a
-- cargar su perfil (nadie ejecutaba ese SELECT antes).
--
-- Idénticas a la 010 salvo el search_path. No cambia firma ni lógica.

-- ── get_my_profile ─────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_profile();
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT[], idiomas TEXT,
              provincia TEXT, localidad TEXT, acuerdo_legal BOOLEAN,
              acuerdo_legal_version TEXT, terminos_vigentes_version TEXT,
              estado_verificacion TEXT, bloqueada BOOLEAN, bloqueada_motivo TEXT,
              consentimiento_fotos BOOLEAN, consentimiento_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  key TEXT;
  uid UUID;
  v_vigente TEXT;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN RETURN; END IF;

  SELECT value INTO key FROM secrets WHERE name = 'enc_key';
  SELECT t.version INTO v_vigente FROM terminos_vigentes() t;

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello,
         e.servicios, e.idiomas,
         e.provincia, e.localidad, e.acuerdo_legal,
         e.acuerdo_legal_version, v_vigente,
         e.estado_verificacion, e.bloqueada, e.bloqueada_motivo,
         e.consentimiento_fotos, e.consentimiento_at
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

-- ── get_escort_decrypted ───────────────────────────────────────────
DROP FUNCTION IF EXISTS get_escort_decrypted(TEXT);
CREATE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT[], idiomas TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello,
         e.servicios, e.idiomas
  FROM escorts e
  WHERE e.slug = slug_param
    AND e.bloqueada = false
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION get_escort_decrypted(TEXT) TO anon, authenticated;
