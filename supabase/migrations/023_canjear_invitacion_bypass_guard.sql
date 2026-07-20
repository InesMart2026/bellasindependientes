-- Migración: canjear_invitacion tiene que prender app.bypass_guard antes de
-- publicar a la escort verificada. Sin esto no se le activa el slot y el panel
-- la manda a pagar, aunque la invitación sea gratis.
--
-- Bug real: guard_protected_columns (013) congela activa y visible_hasta para
-- todo lo que no sea service_role ni tenga app.bypass_guard='on'. activate_slot
-- justo escribe esas dos columnas. Cuando lo llama el webhook de MercadoPago
-- corre como service_role → exento. Pero cuando lo llama canjear_invitacion
-- (SECURITY DEFINER, con el JWT de la escort) el trigger le revierte
-- activa=true y visible_hasta: el pago gratis queda registrado pero la escort
-- NO queda publicada → entra al panel y ve "contratá/renová".
--
-- Fix: mismo patrón que activate_verification (014) y accept_terms (013).
-- Prendemos el flag con SET LOCAL (solo esta transacción) antes de activate_slot.
-- El navegador no puede setearlo, así que las columnas siguen congeladas para
-- el cliente; solo esta RPC confiable las libera, y solo mientras publica.

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

  -- Habilita el UPDATE de activa/visible_hasta que hace activate_slot: sin este
  -- flag el guard (013) las revierte y la escort no queda publicada. SET LOCAL
  -- lo limita a esta transacción.
  PERFORM set_config('app.bypass_guard', 'on', true);

  PERFORM activate_slot(v_pago, 'invitacion_gratis');

  -- Crédito consumido: la escort ya está publicada.
  UPDATE escorts SET credito_dias_gratis = 0 WHERE id = v_escort.id;

  RETURN jsonb_build_object('ok', true, 'activada', true, 'dias', v_dias);
END;
$$;

REVOKE ALL ON FUNCTION canjear_invitacion(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION canjear_invitacion(TEXT) TO authenticated;

-- aplicar_credito_gratis (botón "Publicar mi semana gratis" del panel) tiene
-- el mismo defecto: llama a activate_slot sin bypass y el guard le revierte la
-- publicación. Es el fallback para "verifiqué después de reclamar", así que
-- también hay que arreglarlo o el crédito quedaría imposible de aplicar.
CREATE OR REPLACE FUNCTION aplicar_credito_gratis()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  uid      UUID := auth.uid();
  v_escort RECORD;
  v_pkg    UUID;
  v_pago   UUID;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_autenticado');
  END IF;

  SELECT id, credito_dias_gratis, estado_verificacion INTO v_escort
    FROM escorts WHERE user_id = uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_perfil');
  END IF;

  IF v_escort.credito_dias_gratis <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_credito');
  END IF;

  -- Barrera legal: sin KYC aprobado no se publica, ni gratis.
  IF v_escort.estado_verificacion <> 'verificado' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_kyc');
  END IF;

  SELECT id INTO v_pkg FROM packages WHERE nombre = 'Invitación 7 días' LIMIT 1;
  IF v_pkg IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'paquete_inexistente');
  END IF;

  INSERT INTO pagos (escort_id, package_id, monto, dias, horas, status)
  VALUES (v_escort.id, v_pkg, 0, v_escort.credito_dias_gratis, 0, 'pending')
  RETURNING id INTO v_pago;

  -- Mismo bypass que canjear_invitacion: sin esto el guard revierte activa
  -- y visible_hasta y la escort no queda publicada.
  PERFORM set_config('app.bypass_guard', 'on', true);

  PERFORM activate_slot(v_pago, 'invitacion_gratis');

  -- Consumido: el crédito no se puede volver a aplicar.
  UPDATE escorts SET credito_dias_gratis = 0 WHERE id = v_escort.id;

  RETURN jsonb_build_object('ok', true, 'dias', v_escort.credito_dias_gratis);
END;
$$;

REVOKE ALL ON FUNCTION aplicar_credito_gratis() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aplicar_credito_gratis() TO authenticated;
