-- ─────────────────────────────────────────────────────────────
-- 012 · El perfil público se completa DESPUÉS de verificar identidad
-- ─────────────────────────────────────────────────────────────
-- El onboarding se invirtió: la escort primero se registra y verifica
-- su identidad (datos legales + KYC), y recién después crea el perfil
-- público. La fila `escorts` ahora nace en el paso de verificación con
-- solo los datos legales; nombre/slug/categoría todavía no existen.
--
-- Estas tres columnas eran NOT NULL desde el schema base, así que ese
-- INSERT temprano fallaba con el genérico "revisá que los datos estén
-- completos". Se relajan a nullable: se llenan al guardar Mi Perfil.
--
-- El CHECK de categoría se mantiene (en Postgres un CHECK pasa cuando el
-- valor es NULL) y el UNIQUE de slug también (varios NULL no colisionan).

ALTER TABLE escorts ALTER COLUMN nombre    DROP NOT NULL;
ALTER TABLE escorts ALTER COLUMN slug      DROP NOT NULL;
ALTER TABLE escorts ALTER COLUMN categoria DROP NOT NULL;
