-- ─────────────────────────────────────────────────────────────
-- 018 · KYC: auto-aprobación por score + intentos con enfriamiento
-- ─────────────────────────────────────────────────────────────
-- Problema real del "bucle": Didit devuelve "In Review" (no Approved) a
-- escorts con biometría excelente cuando falla un chequeo SECUNDARIO
-- (OCR de fecha de nacimiento, LIVENESS_MAX_ATTEMPTS_EXCEEDED, dirección
-- no parseada). El webhook mapeaba "In Review" → 'pending' → el ELSE de
-- activate_verification dejaba a la escort en 'en_revision' PARA SIEMPRE:
-- no hay panel que la apruebe a mano, así que nunca pasaba el gate.
--
-- Regla nueva (auditada, no ad-hoc): si la comparación facial y el
-- liveness superan 85, la identidad ES válida aunque Didit marque "In
-- Review" por un chequeo secundario. Se aprueba automáticamente y los
-- scores quedan en kyc_verifications.raw como evidencia. Bajo el umbral
-- NO se aprueba: cuenta como intento fallido para que reintente.
--
-- Umbral: face_match >= 85 Y liveness >= 85 (ambos, no promedio).

-- ── 1. activate_verification con scores explícitos y regla de umbral ──
-- Nueva firma: agrega face_score / liveness_score. El webhook los extrae
-- del payload de Didit. new_status sigue siendo el status crudo mapeado
-- ('approved' | 'declined' | 'pending' | 'abandoned').
DROP FUNCTION IF EXISTS activate_verification(TEXT, TEXT, NUMERIC, JSONB);
CREATE OR REPLACE FUNCTION activate_verification(
  session_id     TEXT,
  new_status     TEXT,
  new_score      NUMERIC,   -- face_match, se conserva en kyc.score por compat
  payload        JSONB,
  face_score     NUMERIC DEFAULT NULL,
  liveness_score NUMERIC DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  eid           UUID;
  -- Umbral de auto-aprobación. Si en el futuro se ajusta, se cambia acá:
  -- queda documentado en la migración, no disperso en el código del edge.
  umbral        CONSTANT NUMERIC := 85;
  aprueba_score BOOLEAN;
  estado_final  TEXT;
BEGIN
  -- Persistir SIEMPRE el resultado crudo de Didit (evidencia legal).
  UPDATE kyc_verifications
    SET status = new_status,
        score = new_score,
        raw = payload,
        updated_at = now()
  WHERE didit_session_id = session_id
  RETURNING escort_id INTO eid;

  IF eid IS NULL THEN RETURN; END IF;

  -- ¿La biometría alcanza el umbral? Ambos scores deben venir y superar 85.
  aprueba_score := face_score IS NOT NULL
                   AND liveness_score IS NOT NULL
                   AND face_score >= umbral
                   AND liveness_score >= umbral;

  -- Mapeo del estado de la escort:
  --  · approved de Didit                → verificado (siempre)
  --  · in review con biometría >= 85/85 → verificado (regla nueva, auditada)
  --  · declined                         → rechazado (la UI lo trata como reintento)
  --  · resto sin alcanzar umbral        → rechazado (reintenta, no queda colgada)
  estado_final := CASE
    WHEN new_status = 'approved' THEN 'verificado'
    WHEN aprueba_score           THEN 'verificado'
    WHEN new_status = 'declined' THEN 'rechazado'
    ELSE 'rechazado'
  END;

  -- Habilita el UPDATE de la columna congelada solo en esta transacción.
  PERFORM set_config('app.bypass_guard', 'on', true);

  UPDATE escorts SET estado_verificacion = estado_final WHERE id = eid;
END;
$$;

-- La RPC solo la invoca el webhook con service_role. No se otorga a
-- authenticated: el navegador no puede auto-verificarse.
REVOKE ALL ON FUNCTION activate_verification(TEXT, TEXT, NUMERIC, JSONB, NUMERIC, NUMERIC) FROM PUBLIC, anon, authenticated;

-- ── 2. Contador de intentos para el enfriamiento ───────────────────
-- crear-kyc pregunta cuántas sesiones abrió la escort en la última hora.
-- Si llegó al límite, se le hace esperar. Cuenta sesiones reales (filas
-- kyc_verifications), no clics: cada intento de Didit deja una fila.
DROP FUNCTION IF EXISTS kyc_attempts_last_hour(UUID);
CREATE FUNCTION kyc_attempts_last_hour(escort_id_param UUID)
RETURNS TABLE(intentos INTEGER, ultimo_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT COUNT(*)::INTEGER, MAX(created_at)
  FROM kyc_verifications
  WHERE escort_id = escort_id_param
    AND created_at > now() - INTERVAL '1 hour';
$$;

REVOKE ALL ON FUNCTION kyc_attempts_last_hour(UUID) FROM PUBLIC, anon, authenticated;
