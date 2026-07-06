-- Migración: campos ricos de perfil (estilo directorio de escorts).
-- Ninguno es sensible → no pasan por el trigger de encriptación.
-- Correr en el SQL Editor de Supabase DESPUÉS de 001 y 002.

-- ─────────────────────────────────────────────────────────────
-- 1. Nuevas columnas en escorts (todas opcionales)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS tarifa        NUMERIC;   -- precio por hora, ARS
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS zona          TEXT;      -- barrio / zona precisa
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS horario       TEXT;      -- ej: "10 a 22 hs"
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS nacionalidad  TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS altura        INTEGER;   -- en cm
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS ojos          TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS cabello       TEXT;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS servicios     TEXT;      -- texto libre, separado por comas
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS idiomas       TEXT;      -- texto libre, separado por comas

-- ─────────────────────────────────────────────────────────────
-- 2. Actualizar las funciones RPC para devolver los campos nuevos.
--    Se borran primero: no se puede cambiar el tipo de salida con REPLACE.
--    (Versión previa vino de la migración 001, con visible_hasta.)
-- ─────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_my_profile();
DROP FUNCTION IF EXISTS get_escort_decrypted(TEXT);

CREATE OR REPLACE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ,
              created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT,
              altura INTEGER, ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT)
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
         e.tarifa, e.zona, e.horario, e.nacionalidad,
         e.altura, e.ojos, e.cabello, e.servicios, e.idiomas
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

CREATE OR REPLACE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ,
              created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT,
              altura INTEGER, ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT)
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
         e.tarifa, e.zona, e.horario, e.nacionalidad,
         e.altura, e.ojos, e.cabello, e.servicios, e.idiomas
  FROM escorts e
  WHERE e.slug = slug_param
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;
