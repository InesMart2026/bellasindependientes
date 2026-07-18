-- ─────────────────────────────────────────────────────────────
-- 019 · KYC: zona gris → revisión humana + panel de pendientes
-- ─────────────────────────────────────────────────────────────
-- La migración 018 partía el veredicto en dos: >=85/85 → verificado,
-- resto → rechazado. Problema: una identidad real con score en la
-- frontera (o un "In Review" de Didit por un chequeo secundario) se
-- aprobaba o se rechazaba sin que nadie mirara. Para cubrirnos legal
-- como hace Skokka —sin perder la velocidad en los casos claros— se
-- agrega un TRAMO INTERMEDIO que va a revisión humana de Ines.
--
-- Tres tramos (umbrales configurables acá, no dispersos en el edge):
--   · face>=90 Y liveness>=90 (o Didit "approved") → verificado (auto)
--   · 85 <= score < 90  (zona gris) o "In Review"  → en_revision + manual
--   · score < 85                                    → rechazado (reintenta)
--
-- La cola manual NO usa un estado nuevo (el CHECK de la 004 solo admite
-- pendiente/en_revision/verificado/rechazado). Reusa 'en_revision' y se
-- distingue de "esperando a Didit" con kyc_verifications.revision_manual.

-- ── 1. Flag de cola manual en la sesión KYC ────────────────────────
ALTER TABLE kyc_verifications
  ADD COLUMN IF NOT EXISTS revision_manual BOOLEAN NOT NULL DEFAULT false;
-- notificada_at: cuándo se avisó a Ines por mail. NULL = pendiente de aviso.
-- Permite agrupar el resumen nocturno sin re-mandar mails ya enviados.
ALTER TABLE kyc_verifications
  ADD COLUMN IF NOT EXISTS notificada_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS kyc_revision_manual_idx
  ON kyc_verifications (revision_manual) WHERE revision_manual = true;

-- ── 2. activate_verification con tramo gris ────────────────────────
-- Misma firma que la 018 (el webhook no cambia su llamada). Agrega el
-- umbral alto y la rama de revisión manual.
CREATE OR REPLACE FUNCTION activate_verification(
  session_id     TEXT,
  new_status     TEXT,
  new_score      NUMERIC,
  payload        JSONB,
  face_score     NUMERIC DEFAULT NULL,
  liveness_score NUMERIC DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  eid           UUID;
  -- Auto-aprueba solo con biometría alta. Entre gris_min y umbral_auto
  -- lo mira Ines. Cambiar los cortes acá, quedan documentados.
  umbral_auto   CONSTANT NUMERIC := 90;   -- >= esto: verificado automático
  gris_min      CONSTANT NUMERIC := 85;   -- >= esto y < umbral_auto: manual
  ambos_ok      BOOLEAN;
  zona_gris     BOOLEAN;
  estado_final  TEXT;
  es_manual     BOOLEAN := false;
BEGIN
  ambos_ok  := face_score IS NOT NULL AND liveness_score IS NOT NULL
               AND face_score >= umbral_auto AND liveness_score >= umbral_auto;
  -- Gris: ambos scores presentes, ambos >= 85, pero al menos uno < 90.
  zona_gris := face_score IS NOT NULL AND liveness_score IS NOT NULL
               AND face_score >= gris_min AND liveness_score >= gris_min
               AND NOT ambos_ok;

  -- Mapeo del estado de la escort:
  --  · approved de Didit / biometría >=90/90 → verificado (auto)
  --  · zona gris, o "In Review" con datos     → en_revision + manual (Ines)
  --  · declined / bajo 85                      → rechazado (reintenta)
  IF new_status = 'approved' OR ambos_ok THEN
    estado_final := 'verificado';
  ELSIF new_status = 'declined' THEN
    estado_final := 'rechazado';
  ELSIF zona_gris OR (new_status = 'pending' AND face_score IS NOT NULL) THEN
    -- Biometría razonable pero no auto-aprobable: la revisa un humano.
    estado_final := 'en_revision';
    es_manual := true;
  ELSE
    estado_final := 'rechazado';
  END IF;

  -- Persistir el resultado crudo (evidencia) + la marca de cola manual.
  UPDATE kyc_verifications
    SET status = new_status,
        score = new_score,
        raw = payload,
        revision_manual = es_manual,
        updated_at = now()
  WHERE didit_session_id = session_id
  RETURNING escort_id INTO eid;

  IF eid IS NULL THEN RETURN; END IF;

  PERFORM set_config('app.bypass_guard', 'on', true);
  UPDATE escorts SET estado_verificacion = estado_final WHERE id = eid;
END;
$$;

REVOKE ALL ON FUNCTION activate_verification(TEXT, TEXT, NUMERIC, JSONB, NUMERIC, NUMERIC)
  FROM PUBLIC, anon, authenticated;

-- ── 3. RPC: listado de pendientes para el panel de Ines ────────────
-- Devuelve solo lo que Ines necesita para decidir: alias/slug, scores y
-- foto de portada. NUNCA datos sensibles (DNI, nombre real, selfie): esos
-- viven encriptados o en Didit. La decisión se toma con score + foto
-- pública; el documento se ve en el panel de Didit si hiciera falta.
DROP FUNCTION IF EXISTS kyc_pendientes_manual();
CREATE FUNCTION kyc_pendientes_manual()
RETURNS TABLE(
  session_id   TEXT,
  escort_id    UUID,
  nombre       TEXT,
  slug         TEXT,
  face_score   NUMERIC,
  liveness_score NUMERIC,
  portada_url  TEXT,
  created_at   TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT
    k.didit_session_id,
    e.id,
    e.nombre,
    e.slug,
    GREATEST(
      COALESCE((k.raw->'decision'->'face_match'->>'score')::numeric, 0),
      COALESCE((SELECT MAX((x->>'score')::numeric)
                FROM jsonb_array_elements(k.raw->'decision'->'face_matches') x), 0)
    ) AS face_score,
    GREATEST(
      COALESCE((k.raw->'decision'->'liveness'->>'score')::numeric, 0),
      COALESCE((SELECT MAX((x->>'score')::numeric)
                FROM jsonb_array_elements(k.raw->'decision'->'liveness_checks') x), 0)
    ) AS liveness_score,
    -- La portada vive en photos.url (URL pública ya armada). Se prefiere la
    -- marcada es_portada; si no hay, la primera por orden. Puede ser NULL.
    COALESCE(
      (SELECT p.url FROM photos p
        WHERE p.escort_id = e.id AND p.es_portada = true LIMIT 1),
      (SELECT p.url FROM photos p
        WHERE p.escort_id = e.id ORDER BY p.orden ASC LIMIT 1)
    ) AS portada_url,
    k.created_at
  FROM kyc_verifications k
  JOIN escorts e ON e.id = k.escort_id
  WHERE k.revision_manual = true
    AND e.estado_verificacion = 'en_revision'
  ORDER BY k.created_at ASC;
$$;

REVOKE ALL ON FUNCTION kyc_pendientes_manual() FROM PUBLIC, anon, authenticated;

-- ── 4. RPC: resolver una revisión manual (aprobar / rechazar) ──────
-- La invoca la Edge Function admin-kyc con service_role tras validar la
-- clave admin. Reusa el bypass_guard para tocar la columna congelada.
DROP FUNCTION IF EXISTS resolver_revision_manual(TEXT, BOOLEAN);
CREATE FUNCTION resolver_revision_manual(session_id TEXT, aprobar BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  eid UUID;
BEGIN
  -- Solo resuelve sesiones que realmente están en la cola manual.
  UPDATE kyc_verifications
    SET revision_manual = false, updated_at = now()
  WHERE didit_session_id = session_id AND revision_manual = true
  RETURNING escort_id INTO eid;

  IF eid IS NULL THEN RETURN false; END IF;

  PERFORM set_config('app.bypass_guard', 'on', true);
  UPDATE escorts
    SET estado_verificacion = CASE WHEN aprobar THEN 'verificado' ELSE 'rechazado' END
  WHERE id = eid;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION resolver_revision_manual(TEXT, BOOLEAN)
  FROM PUBLIC, anon, authenticated;

-- ── 5. RPC: pendientes sin notificar (para el mail a Ines) ─────────
-- El webhook, tras marcar una revisión manual, pregunta si corresponde
-- avisar. En horario diurno (8-21) avisa al instante; de noche deja que
-- se acumulen y el resumen sale a la mañana. Devuelve las no notificadas
-- y las marca en el mismo paso (evita doble aviso ante reintentos).
DROP FUNCTION IF EXISTS kyc_tomar_pendientes_sin_notificar();
CREATE FUNCTION kyc_tomar_pendientes_sin_notificar()
RETURNS TABLE(session_id TEXT, nombre TEXT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  RETURN QUERY
  WITH tomadas AS (
    UPDATE kyc_verifications k
      SET notificada_at = now()
    FROM escorts e
    WHERE e.id = k.escort_id
      AND k.revision_manual = true
      AND k.notificada_at IS NULL
      AND e.estado_verificacion = 'en_revision'
    RETURNING k.didit_session_id, e.nombre, k.created_at
  )
  SELECT t.didit_session_id, t.nombre, t.created_at FROM tomadas t
  ORDER BY t.created_at ASC;
END;
$$;

REVOKE ALL ON FUNCTION kyc_tomar_pendientes_sin_notificar()
  FROM PUBLIC, anon, authenticated;
