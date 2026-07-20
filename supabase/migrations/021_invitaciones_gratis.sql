-- Migración: invitaciones de 1 semana gratis para captar escorts.
--
-- Cómo encaja sin tocar el flujo de pago existente:
--   · Cada invitación es un token de un solo uso, con caducidad propia.
--   · Reclamar el token NO activa el perfil: deja un CRÉDITO en la cuenta.
--   · El crédito se cobra recién cuando la escort YA está verificada (KYC) y
--     publica → ahí se llama a activate_slot con un pago gratis de 7 días,
--     exactamente por la misma vía que un pago real de MercadoPago.
--   · Así el link se quema al reclamarlo (no se puede recompartir) pero la
--     semana gratis empieza a correr cuando el perfil realmente sale al aire.
--
-- Nada de esto modifica crear-pago, el webhook ni activate_slot.

-- ─────────────────────────────────────────────────────────────
-- 1. Paquete de 7 días gratis. activo=false → NO aparece en planes.html
--    ni en el dashboard; solo lo referencia el canje del crédito.
-- ─────────────────────────────────────────────────────────────
INSERT INTO packages (nombre, dias, horas, precio_total, precio_dia, destacada, activo, orden)
SELECT 'Invitación 7 días', 7, 0, 0, 0, false, false, 99
WHERE NOT EXISTS (SELECT 1 FROM packages WHERE nombre = 'Invitación 7 días');

-- ─────────────────────────────────────────────────────────────
-- 2. Tabla de invitaciones (tokens de un solo uso)
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invitaciones (
  id          UUID PRIMARY KEY DEFAULT extensions.uuid_generate_v4(),
  codigo      TEXT UNIQUE NOT NULL,        -- token del link ?code=...
  dias_regalo INTEGER NOT NULL DEFAULT 7,
  expira_el   TIMESTAMPTZ NOT NULL,        -- caducidad del link en sí
  usado       BOOLEAN NOT NULL DEFAULT false,
  usada_por   UUID REFERENCES escorts(id) ON DELETE SET NULL,
  usada_el    TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- RLS cerrada: nadie lee/escribe esta tabla vía API. Solo la RPC
-- SECURITY DEFINER de abajo (y el service_role) la tocan.
ALTER TABLE invitaciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "invitaciones_no_access" ON invitaciones;
CREATE POLICY "invitaciones_no_access" ON invitaciones FOR ALL USING (false);

-- ─────────────────────────────────────────────────────────────
-- 3. Crédito de días gratis pendiente de aplicar, colgado del perfil.
--    Un crédito por escort (el que reclamó su invitación).
-- ─────────────────────────────────────────────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS credito_dias_gratis INTEGER NOT NULL DEFAULT 0;

-- ─────────────────────────────────────────────────────────────
-- 4. Canjear invitación → quema el token y deja el crédito.
--    Atómico: el UPDATE con WHERE usado=false es lo que impide el doble uso.
--    Se llama con el JWT de la escort (resuelve el perfil por auth.uid()).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION canjear_invitacion(p_codigo TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions AS $$
DECLARE
  uid       UUID := auth.uid();
  v_escort  RECORD;
  v_dias    INTEGER;
  v_filas   INTEGER;
BEGIN
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_autenticado');
  END IF;

  SELECT id, credito_dias_gratis INTO v_escort
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

  UPDATE escorts SET credito_dias_gratis = v_dias WHERE id = v_escort.id;

  RETURN jsonb_build_object('ok', true, 'dias', v_dias);
END;
$$;

REVOKE ALL ON FUNCTION canjear_invitacion(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION canjear_invitacion(TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 5. Aplicar el crédito → activa la semana gratis por la vía de activate_slot.
--    Exige KYC aprobado (misma barrera legal que crear-pago). Inserta un pago
--    gratis ya aprobado y llama activate_slot, que suma los 7 días al slot.
-- ─────────────────────────────────────────────────────────────
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

  -- Pago gratis pendiente; activate_slot lo aprueba y suma los días.
  INSERT INTO pagos (escort_id, package_id, monto, dias, horas, status)
  VALUES (v_escort.id, v_pkg, 0, v_escort.credito_dias_gratis, 0, 'pending')
  RETURNING id INTO v_pago;

  PERFORM activate_slot(v_pago, 'invitacion_gratis');

  -- Consumido: el crédito no se puede volver a aplicar.
  UPDATE escorts SET credito_dias_gratis = 0 WHERE id = v_escort.id;

  RETURN jsonb_build_object('ok', true, 'dias', v_escort.credito_dias_gratis);
END;
$$;

REVOKE ALL ON FUNCTION aplicar_credito_gratis() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aplicar_credito_gratis() TO authenticated;

-- ─────────────────────────────────────────────────────────────
-- 6. Generar 10 invitaciones que caducan en 30 días.
--    Los códigos salen en el output del push (o consultá la tabla luego).
-- ─────────────────────────────────────────────────────────────
-- Idempotente: solo genera si la tabla está vacía. Reejecutar la migración
-- (p. ej. tras un fallo a mitad) no duplica tokens.
INSERT INTO invitaciones (codigo, dias_regalo, expira_el)
SELECT encode(extensions.gen_random_bytes(12), 'hex'), 7, now() + interval '30 days'
FROM generate_series(1, 10)
WHERE NOT EXISTS (SELECT 1 FROM invitaciones);
