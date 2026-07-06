-- Paquetes de visibilidad (pay-per-day con descuento por volumen).
-- Base: $15.000 ARS/día. El precio/día baja al comprar más días.
-- Los paquetes de 15 y 30 días compran además posición destacada.

-- Idempotente: solo siembra si la tabla está vacía (evita duplicar al re-correr).
INSERT INTO packages (nombre, dias, precio_total, precio_dia, destacada, orden)
SELECT * FROM (VALUES
  ('1 día',   1,  15000,  15000, false, 1),
  ('7 días',  7,  91000,  13000, false, 2),
  ('15 días', 15, 172500, 11500, true,  3),
  ('30 días', 30, 300000, 10000, true,  4)
) AS v(nombre, dias, precio_total, precio_dia, destacada, orden)
WHERE NOT EXISTS (SELECT 1 FROM packages);
