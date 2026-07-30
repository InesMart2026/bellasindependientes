-- ═══════════════════════════════════════════════════════════════════
-- RESCATE: desbloquear escorts colgadas en 'en_revision' con biometría OK
-- Correr DESPUÉS de aplicar la migración 018.
-- ═══════════════════════════════════════════════════════════════════

-- ── PASO 1 (solo mirar): quiénes están colgadas y con qué scores ──
-- Revisá esta lista antes de tocar nada. face y liveness salen del raw
-- de Didit tolerando objeto o array (misma lógica que el webhook).
WITH ult AS (
  SELECT DISTINCT ON (k.escort_id)
    k.escort_id, k.didit_session_id, k.status, k.raw, k.created_at
  FROM kyc_verifications k
  ORDER BY k.escort_id, k.created_at DESC
),
scored AS (
  SELECT
    u.escort_id, u.didit_session_id, u.status,
    GREATEST(
      COALESCE((u.raw->'decision'->'face_match'->>'score')::numeric, 0),
      COALESCE((SELECT MAX((x->>'score')::numeric)
                FROM jsonb_array_elements(u.raw->'decision'->'face_matches') x), 0)
    ) AS face,
    GREATEST(
      COALESCE((u.raw->'decision'->'liveness'->>'score')::numeric, 0),
      COALESCE((SELECT MAX((x->>'score')::numeric)
                FROM jsonb_array_elements(u.raw->'decision'->'liveness_checks') x), 0)
    ) AS liveness
  FROM ult u
)
SELECT s.escort_id, e.estado_verificacion, s.status AS didit_status,
       s.face, s.liveness,
       (s.face >= 85 AND s.liveness >= 85) AS pasaria_umbral
FROM scored s
JOIN escorts e ON e.id = s.escort_id
WHERE e.estado_verificacion = 'en_revision'
ORDER BY pasaria_umbral DESC, s.face DESC;

-- ── PASO 2 (aplicar): aprobar SOLO las que pasan 85/85 ──
-- Descomentá y corré una vez revisado el PASO 1. Reusa la RPC oficial
-- (misma lógica de auditoría) en vez de un UPDATE suelto: pasa por el
-- bypass_guard y deja el raw intacto.
--
-- DO $$
-- DECLARE r RECORD;
-- BEGIN
--   FOR r IN
--     WITH ult AS (
--       SELECT DISTINCT ON (k.escort_id)
--         k.escort_id, k.didit_session_id, k.raw
--       FROM kyc_verifications k
--       ORDER BY k.escort_id, k.created_at DESC
--     )
--     SELECT u.didit_session_id, u.raw,
--       GREATEST(
--         COALESCE((u.raw->'decision'->'face_match'->>'score')::numeric, 0),
--         COALESCE((SELECT MAX((x->>'score')::numeric)
--                   FROM jsonb_array_elements(u.raw->'decision'->'face_matches') x), 0)
--       ) AS face,
--       GREATEST(
--         COALESCE((u.raw->'decision'->'liveness'->>'score')::numeric, 0),
--         COALESCE((SELECT MAX((x->>'score')::numeric)
--                   FROM jsonb_array_elements(u.raw->'decision'->'liveness_checks') x), 0)
--       ) AS liveness
--     FROM ult u
--     JOIN escorts e ON e.id = u.escort_id
--     WHERE e.estado_verificacion = 'en_revision'
--   LOOP
--     IF r.face >= 85 AND r.liveness >= 85 THEN
--       PERFORM activate_verification(
--         r.didit_session_id, 'pending', r.face, r.raw, r.face, r.liveness);
--     END IF;
--   END LOOP;
-- END $$;
