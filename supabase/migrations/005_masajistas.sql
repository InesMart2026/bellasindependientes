-- 005_masajistas.sql
-- Agrega la categoría 'masajistas'. El CHECK original es inline y sin nombre
-- explícito, por lo que Postgres lo nombró 'escorts_categoria_check'.
-- Lo reemplazamos para admitir la nueva categoría sin perder la validación.

ALTER TABLE escorts DROP CONSTRAINT IF EXISTS escorts_categoria_check;

ALTER TABLE escorts
  ADD CONSTRAINT escorts_categoria_check
  CHECK (categoria IN ('mujeres', 'hombres', 'trans', 'masajistas'));
