-- ═══════════════════════════════════════════════════════════════════
-- 011 — La escort elige EN QUÉ PROVINCIA se publica (lista cerrada).
--
-- Hasta acá `escorts.ubicacion` era TEXT libre ("Ej: Buenos Aires"). Se
-- muestra en la tarjeta y el buscador ya filtra por él, pero como cada
-- una escribe lo que quiere ("Tucumán", "tucuman", "S.M. de Tucumán"),
-- agrupar por provincia era imposible. No se agrega una columna nueva:
-- se le pone forma a la que ya existe y ya se usa.
--
-- OJO, no confundir con `escorts.provincia` (migración 004): esa es dato
-- LEGAL (dónde vive la persona, va con el KYC). Ésta es dato de ANUNCIO
-- (dónde ofrece el servicio). Pueden no coincidir y está bien que así sea.
--
-- Igual que con `servicios`: el dashboard hace .update() directo desde el
-- navegador, así que un <select> en el HTML no valida nada — se saltea
-- desde la consola. La lista cerrada se aplica acá.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Catálogo de provincias ──────────────────────────────────────
-- En tabla y no en un CHECK hardcodeado, por el mismo motivo que
-- servicios_catalogo: sumar o retirar una jurisdicción es un INSERT o un
-- UPDATE, no una migración. `activo` permite abrir el sitio provincia por
-- provincia sin borrar nada.
CREATE TABLE IF NOT EXISTS provincias_catalogo (
  slug   TEXT PRIMARY KEY,
  nombre TEXT NOT NULL,
  orden  INTEGER NOT NULL DEFAULT 0,
  activo BOOLEAN NOT NULL DEFAULT true
);

-- Las 24 jurisdicciones. Tucumán primero (es el mercado del sitio), el
-- resto alfabético. El `slug` es lo que se guarda en escorts.ubicacion:
-- sin tildes ni espacios, así sirve para una URL /tucuman/ el día que
-- convenga separar por página.
INSERT INTO provincias_catalogo (slug, nombre, orden) VALUES
  ('tucuman',            'Tucumán',                          1),
  ('buenos-aires',       'Buenos Aires',                    10),
  ('caba',               'Ciudad de Buenos Aires',          20),
  ('catamarca',          'Catamarca',                       30),
  ('chaco',              'Chaco',                           40),
  ('chubut',             'Chubut',                          50),
  ('cordoba',            'Córdoba',                         60),
  ('corrientes',         'Corrientes',                      70),
  ('entre-rios',         'Entre Ríos',                      80),
  ('formosa',            'Formosa',                         90),
  ('jujuy',              'Jujuy',                          100),
  ('la-pampa',           'La Pampa',                       110),
  ('la-rioja',           'La Rioja',                       120),
  ('mendoza',            'Mendoza',                        130),
  ('misiones',           'Misiones',                       140),
  ('neuquen',            'Neuquén',                        150),
  ('rio-negro',          'Río Negro',                      160),
  ('salta',              'Salta',                          170),
  ('san-juan',           'San Juan',                       180),
  ('san-luis',           'San Luis',                       190),
  ('santa-cruz',         'Santa Cruz',                     200),
  ('santa-fe',           'Santa Fe',                       210),
  ('santiago-del-estero','Santiago del Estero',            220),
  ('tierra-del-fuego',   'Tierra del Fuego',               230)
ON CONFLICT (slug) DO NOTHING;

ALTER TABLE provincias_catalogo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "provincias lectura pública" ON provincias_catalogo;
CREATE POLICY "provincias lectura pública" ON provincias_catalogo
  FOR SELECT USING (activo = true);

-- ── 2. Rescatar lo que ya se escribió a mano ───────────────────────
-- La base está prácticamente vacía, pero si hay perfiles viejos con
-- ubicación en texto libre, se intenta mapearlos antes de exigir la lista.
-- Match tolerante: sin tildes, sin mayúsculas. Lo que no matchea queda en
-- NULL y la escort la vuelve a elegir — inventar la provincia de alguien
-- es peor que pedirle que la confirme.
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS ubicacion_legacy TEXT;

UPDATE escorts e
   SET ubicacion_legacy = e.ubicacion
 WHERE e.ubicacion IS NOT NULL
   AND e.ubicacion_legacy IS NULL;

-- translate() en vez de la extensión unaccent: es una sola comparación en
-- una tabla mínima, no vale instalar una extensión para esto.
UPDATE escorts e
   SET ubicacion = c.slug
  FROM provincias_catalogo c
 WHERE e.ubicacion IS NOT NULL
   AND e.ubicacion <> c.slug
   AND translate(lower(trim(e.ubicacion)), 'áéíóúü', 'aeiouu')
     = translate(lower(c.nombre),           'áéíóúü', 'aeiouu');

-- Lo que no se pudo mapear no se conserva: dejarlo rompería el trigger de
-- abajo en el próximo guardado. Queda copiado en ubicacion_legacy.
UPDATE escorts e
   SET ubicacion = NULL
 WHERE e.ubicacion IS NOT NULL
   AND e.ubicacion NOT IN (SELECT slug FROM provincias_catalogo);

-- ── 3. Trigger: rechazar provincias fuera del catálogo ─────────────
-- Ésta es la defensa real. El <select> del dashboard es solo UX.
CREATE OR REPLACE FUNCTION validate_ubicacion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  IF NEW.ubicacion IS NULL OR trim(NEW.ubicacion) = '' THEN
    NEW.ubicacion := NULL;
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM provincias_catalogo
     WHERE slug = NEW.ubicacion AND activo = true
  ) THEN
    RAISE EXCEPTION 'Provincia no permitida: %', NEW.ubicacion;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_ubicacion ON escorts;
CREATE TRIGGER trg_validate_ubicacion
  BEFORE INSERT OR UPDATE OF ubicacion ON escorts
  FOR EACH ROW EXECUTE FUNCTION validate_ubicacion();

-- Índice: el filtro del listado pega sobre esto en cada carga de página.
CREATE INDEX IF NOT EXISTS idx_escorts_ubicacion ON escorts(ubicacion);

-- ── 4. Catálogo público para el front ──────────────────────────────
-- Una RPC en vez de exponer la tabla: el front no depende de la forma
-- interna y el <select> del dashboard y el filtro del listado leen lo mismo.
CREATE OR REPLACE FUNCTION get_provincias_catalogo()
RETURNS TABLE(slug TEXT, nombre TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT c.slug, c.nombre
  FROM provincias_catalogo c
  WHERE c.activo = true
  ORDER BY c.orden;
$$;

GRANT EXECUTE ON FUNCTION get_provincias_catalogo() TO anon, authenticated;
