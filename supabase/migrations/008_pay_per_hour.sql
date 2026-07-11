-- Migración: pago por horas.
-- Los paquetes por hora viven en la misma tabla `packages` y usan el mismo
-- flujo de pago (crear-pago → MercadoPago → webhook → activate_slot).
--
-- Reglas de negocio (para que la hora no canibalice al día):
--   · Precio por hora DECRECIENTE: 3h sale $1.500/h, 12h sale $1.000/h.
--   · La hora nunca compra posición destacada.
--   · Un perfil sostenido solo por horas ordena por DEBAJO de los que pagan
--     por día (columna `slot_por_hora` + orden del grid).
--
-- Al vencer, el perfil NO se borra: deja de ser visible (RLS por visible_hasta)
-- y libera el espacio del grid, pero conserva fotos y verificación para renovar.

-- ─────────────────────────────────────────────────────────────
-- 1. Duración en horas (0 = el paquete usa `dias`)
-- ─────────────────────────────────────────────────────────────
ALTER TABLE packages ADD COLUMN IF NOT EXISTS horas INTEGER NOT NULL DEFAULT 0;
ALTER TABLE pagos    ADD COLUMN IF NOT EXISTS horas INTEGER NOT NULL DEFAULT 0;

-- Un paquete es de días o de horas, nunca ambos ni ninguno.
ALTER TABLE packages DROP CONSTRAINT IF EXISTS packages_duracion_check;
ALTER TABLE packages ADD  CONSTRAINT packages_duracion_check
  CHECK ((dias > 0 AND horas = 0) OR (horas > 0 AND dias = 0));

-- El slot vigente se sostiene solo con horas → va al fondo del listado.
-- Se apaga apenas la escort compra un paquete por día.
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS slot_por_hora BOOLEAN NOT NULL DEFAULT false;

-- ─────────────────────────────────────────────────────────────
-- 2. activate_slot suma horas o días según el paquete comprado.
--    Sigue siendo idempotente y solo la llama el webhook (service_role).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION activate_slot(pago_id UUID, mp_payment TEXT)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  p RECORD;
  base TIMESTAMPTZ;
  vencido BOOLEAN;
  por_hora BOOLEAN;
  duracion INTERVAL;
BEGIN
  SELECT * INTO p FROM pagos WHERE id = pago_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pago no encontrado'; END IF;
  IF p.status = 'approved' THEN RETURN; END IF; -- idempotente

  por_hora := COALESCE(p.horas, 0) > 0;
  duracion := CASE
    WHEN por_hora THEN (p.horas || ' hours')::interval
    ELSE (p.dias || ' days')::interval
  END;

  -- Si el slot sigue vigente, sumamos desde el vencimiento actual.
  -- Si ya venció (o nunca pagó), contamos desde ahora.
  SELECT GREATEST(COALESCE(visible_hasta, now()), now()),
         COALESCE(visible_hasta, now()) <= now()
    INTO base, vencido
    FROM escorts WHERE id = p.escort_id;

  UPDATE escorts
    SET activa = true,
        visible_hasta = base + duracion,
        destacada = destacada OR (SELECT destacada FROM packages WHERE id = p.package_id),
        -- Comprar días saca el perfil del fondo del listado. Comprar horas
        -- solo lo manda al fondo si no tenía días vigentes que preservar.
        slot_por_hora = CASE
          WHEN NOT por_hora THEN false
          WHEN vencido THEN true
          ELSE slot_por_hora
        END
    WHERE id = p.escort_id;

  UPDATE pagos
    SET status = 'approved', mp_payment_id = mp_payment, approved_at = now()
    WHERE id = pago_id;
END;
$$;

-- ─────────────────────────────────────────────────────────────
-- 3. Orden del grid: destacadas → por día → por hora → vencimiento
-- ─────────────────────────────────────────────────────────────
DROP INDEX IF EXISTS idx_escorts_grid;
CREATE INDEX IF NOT EXISTS idx_escorts_grid
  ON escorts (categoria, destacada DESC, slot_por_hora ASC, visible_hasta DESC)
  WHERE activa = true;

-- ─────────────────────────────────────────────────────────────
-- 4. Paquetes por hora — precio decreciente, sin posición destacada.
--    `orden` arranca en 10 para que queden después de los de días.
--    `precio_dia` acá guarda el precio POR HORA (el frontend lo rotula según
--    el tipo de paquete). 3h=$1.500/h … 12h=$1.000/h.
-- ─────────────────────────────────────────────────────────────
INSERT INTO packages (nombre, dias, horas, precio_total, precio_dia, destacada, orden)
SELECT * FROM (VALUES
  ('3 horas',  0, 3,   4500, 1500, false, 10),
  ('5 horas',  0, 5,   6500, 1300, false, 11),
  ('8 horas',  0, 8,   9600, 1200, false, 12),
  ('12 horas', 0, 12, 12000, 1000, false, 13)
) AS v(nombre, dias, horas, precio_total, precio_dia, destacada, orden)
WHERE NOT EXISTS (SELECT 1 FROM packages WHERE horas > 0);
