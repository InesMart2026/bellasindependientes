-- Migración: dejar visibles solo los planes por hora + el plan de 1 día.
--
-- Contexto de negocio: los paquetes largos (7/15/30 días) generan fricción en
-- la decisión de contratar. Se reduce la oferta a pago por hora (baja barrera
-- de entrada) más un único plan diario de $15.000. La página planes.html ya
-- muestra las horas arriba y el plan por día debajo, sin tocar el frontend.
--
-- No se borra nada: desactivar preserva el histórico de pagos (FK) y permite
-- reactivar los paquetes con un solo UPDATE si se decide volver atrás.

UPDATE packages
SET activo = false
WHERE horas = 0 AND dias > 1;

-- Reactivar (rollback):
-- UPDATE packages SET activo = true WHERE horas = 0 AND dias > 1;
