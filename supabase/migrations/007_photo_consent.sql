-- ═══════════════════════════════════════════════════════════════════
-- 007 — Consentimiento verificable de imágenes (registro 2257-style)
--
-- Objetivo:
--  · Antes de que una escort pueda subir fotos, debe dejar una declaración
--    registrada: que es la persona de las imágenes, que era mayor de 18 al
--    tomarlas, y que tiene derecho a publicarlas. Queda con fecha/hora.
--  · Esa declaración es la prueba de consentimiento que exigen las páginas
--    serias del rubro para cubrirse ante contenido no consentido o dudas
--    sobre la edad. Sin ella, el sitio queda expuesto legalmente.
--
-- Marco legal (Argentina):
--  · Ley 27.436 (material de abuso sexual infantil) → dejar constancia de
--    la mayoría de edad al momento de tomar la imagen.
--  · Ley 26.485 y difusión de imágenes íntimas sin consentimiento → prueba
--    de que la titular autorizó la publicación de su propia imagen.
--  · Art. 1710 CCyC (deber de prevención) → gate previo a la publicación.
--
-- Diseño:
--  · Dos columnas en escorts, congeladas para authenticated igual que las
--    de bloqueo: la escort no puede falsear la fecha desde el navegador.
--  · Una RPC SECURITY DEFINER (accept_photo_consent) que marca el
--    consentimiento para la escort del usuario autenticado, con now() del
--    servidor (no una fecha que mande el cliente).
--  · get_my_profile expone el estado para que el dashboard sepa si ya se
--    aceptó y habilite/bloquee la subida.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Columnas de consentimiento en escorts ───────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS consentimiento_fotos BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS consentimiento_at    TIMESTAMPTZ;

-- ── 2. Congelar el consentimiento para el rol authenticated ─────────
-- La fecha del consentimiento la fija el servidor vía RPC, nunca el
-- cliente. Se extiende el guard sumando las 2 columnas nuevas.
CREATE OR REPLACE FUNCTION guard_protected_columns() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- service_role bypassa RLS y corre con otro rol → se le permite todo.
  IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' THEN
    RETURN NEW;
  END IF;

  NEW.estado_verificacion   := OLD.estado_verificacion;
  NEW.activa                := OLD.activa;
  NEW.visible_hasta         := OLD.visible_hasta;
  NEW.destacada             := OLD.destacada;
  NEW.bloqueada             := OLD.bloqueada;
  NEW.bloqueada_motivo      := OLD.bloqueada_motivo;
  NEW.bloqueada_at          := OLD.bloqueada_at;
  NEW.consentimiento_fotos  := OLD.consentimiento_fotos;
  NEW.consentimiento_at     := OLD.consentimiento_at;
  RETURN NEW;
END;
$$;

-- ── 3. RPC: aceptar el consentimiento de fotos ─────────────────────
-- La ejecuta la escort autenticada desde el dashboard. Marca su propio
-- perfil con la fecha del servidor. Idempotente: si ya lo aceptó, no
-- pisa la fecha original (la primera declaración es la que vale).
CREATE OR REPLACE FUNCTION accept_photo_consent()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  uid UUID;
  ya BOOLEAN;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autenticado');
  END IF;

  SELECT consentimiento_fotos INTO ya FROM escorts WHERE user_id = uid;

  IF ya IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'perfil inexistente');
  END IF;

  IF ya THEN
    RETURN jsonb_build_object('ok', true, 'ya', true);
  END IF;

  UPDATE escorts
     SET consentimiento_fotos = true,
         consentimiento_at = now()
   WHERE user_id = uid;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION accept_photo_consent() TO authenticated;

-- ── 4. Exponer el estado de consentimiento en get_my_profile ───────
-- El dashboard usa esto para habilitar o bloquear la subida de fotos.
DROP FUNCTION IF EXISTS get_my_profile();
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT, idiomas TEXT,
              provincia TEXT, localidad TEXT, acuerdo_legal BOOLEAN,
              estado_verificacion TEXT, bloqueada BOOLEAN, bloqueada_motivo TEXT,
              consentimiento_fotos BOOLEAN, consentimiento_at TIMESTAMPTZ)
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
         e.bloqueada, e.bloqueada_motivo,
         e.consentimiento_fotos, e.consentimiento_at
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;
