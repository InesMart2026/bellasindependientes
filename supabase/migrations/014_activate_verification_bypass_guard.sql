-- ─────────────────────────────────────────────────────────────
-- 014 · activate_verification puede escribir estado_verificacion
-- ─────────────────────────────────────────────────────────────
-- Mismo problema que 013 (accept_terms), otra columna congelada.
--
-- guard_protected_columns (013) congela estado_verificacion para todo lo
-- que no sea service_role. El webhook de Didit llama a activate_verification,
-- que corre SECURITY DEFINER; en ese contexto request.jwt.claims->>'role' no
-- siempre trae 'service_role', así que el trigger le revierte el UPDATE de
-- escorts: la sesión kyc quedaba 'approved' pero la escort seguía en
-- 'en_revision' para siempre. Ese era el "bucle": ninguna verificación real
-- llegaba a 'verificado', y el panel rebotaba a la pantalla de verificación.
--
-- Fix: activate_verification prende app.bypass_guard antes de tocar escorts,
-- igual que accept_terms. SET LOCAL lo limita a la transacción. El navegador
-- no puede invocar esta RPC (GRANT solo a service_role vía webhook), así que
-- la columna sigue congelada para el cliente.

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

  -- Habilita el UPDATE de la columna congelada solo en esta transacción:
  -- el trigger guard_protected_columns respeta este flag (ver 013).
  PERFORM set_config('app.bypass_guard', 'on', true);

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
