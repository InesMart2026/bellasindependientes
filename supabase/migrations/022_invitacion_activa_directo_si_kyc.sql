-- Migración: la invitación activa la semana gratis EN EL ACTO si la escort
-- ya tiene el KYC aprobado. Sin segundo paso manual, sin rebotes.
--
-- Problema que corrige (021): canjear_invitacion solo dejaba el crédito y
-- SIEMPRE mandaba a la escort a apretar otro botón en el panel, incluso si ya
-- estaba verificada. Para una escort ya registrada y con KYC hecho eso se veía
-- como "no me da los 7 días" → un rebote innecesario.
--
-- Regla de negocio (confirmada):
--   · Escort YA verificada (pasó KYC)  → se le activan los 7 días al instante.
--   · Escort SIN verificar             → se le reserva el crédito y se la guía
--                                         al KYC (barrera legal, no se saltea).
--
-- No se toca activate_slot, crear-pago ni el webhook. aplicar_credito_gratis
-- queda igual y sigue sirviendo para el caso "verifiqué después de reclamar".

CREATE OR REPLACE FUNCTION canjear_invitacion(p_codigo TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  uid       UUID := auth.uid();
  v_escort  RECORD;
  v_dias    INTEGER;
  v_filas   INTEGER;
  v_pkg     UUID;
  v_pago    UUID;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_autenticado');
  END IF;

  SELECT id, credito_dias_gratis, estado_verificacion INTO v_escort
    FROM escorts WHERE user_id = uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_perfil');
  END IF;

  -- Una escort no puede acumular más de una invitación.
  IF v_escort.credito_dias_gratis > 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'ya_tiene_credito');
  END IF;

  -- Quemar el token de forma atómica: solo prospera si estaba sin usar
  -- y no venció. Dos canjes simultáneos: solo uno afecta la fila.
  UPDATE invitaciones
     SET usado = true, usada_por = v_escort.id, usada_el = now()
   WHERE codigo = p_codigo
     AND usado = false
     AND expira_el > now()
   RETURNING dias_regalo INTO v_dias;

  GET DIAGNOSTICS v_filas = ROW_COUNT;
  IF v_filas = 0 THEN
    -- O no existe, o ya se usó, o venció: no distinguimos para no filtrar info.
    RETURN jsonb_build_object('ok', false, 'error', 'invitacion_invalida');
  END IF;

  -- ── Escort SIN KYC: reservar crédito y guiar a verificación ──────
  -- La semana se activará al terminar el KYC (aplicar_credito_gratis).
  IF v_escort.estado_verificacion <> 'verificado' THEN
    UPDATE escorts SET credito_dias_gratis = v_dias WHERE id = v_escort.id;
    RETURN jsonb_build_object('ok', true, 'activada', false, 'dias', v_dias);
  END IF;

  -- ── Escort YA verificada: activar los 7 días en el acto ──────────
  -- Mismo camino que aplicar_credito_gratis: pago gratis + activate_slot.
  -- No dejamos crédito colgado; se consume acá mismo.
  SELECT id INTO v_pkg FROM packages WHERE nombre = 'Invitación 7 días' LIMIT 1;
  IF v_pkg IS NULL THEN
    -- Sin paquete no podemos activar: dejamos el crédito para el fallback manual.
    UPDATE escorts SET credito_dias_gratis = v_dias WHERE id = v_escort.id;
    RETURN jsonb_build_object('ok', true, 'activada', false, 'dias', v_dias,
                              'error', 'paquete_inexistente');
  END IF;

  INSERT INTO pagos (escort_id, package_id, monto, dias, horas, status)
  VALUES (v_escort.id, v_pkg, 0, v_dias, 0, 'pending')
  RETURNING id INTO v_pago;

  PERFORM activate_slot(v_pago, 'invitacion_gratis');

  -- Crédito consumido: la escort ya está publicada.
  UPDATE escorts SET credito_dias_gratis = 0 WHERE id = v_escort.id;

  RETURN jsonb_build_object('ok', true, 'activada', true, 'dias', v_dias);
END;
$$;

REVOKE ALL ON FUNCTION canjear_invitacion(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION canjear_invitacion(TEXT) TO authenticated;
