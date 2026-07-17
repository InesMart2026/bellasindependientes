-- ── La primera foto de cada escort es la portada ───────────────────
--
-- La card del listado muestra la foto con es_portada = true (fetchPortada
-- en gallery.js). Al subir fotos, ninguna quedaba marcada → la card mostraba
-- "Sin foto" aunque la escort tuviera fotos cargadas. Nadie sabía que había
-- que elegir portada a mano.
--
-- Regla: si la escort no tiene ninguna portada, la foto que se inserta pasa
-- a ser portada. Se resuelve en la DB con un trigger para que valga sin
-- importar desde dónde se suba (front, panel, import), no solo en upload.js.
-- La escort puede cambiarla después con setPortada().

-- Backfill: las escorts que ya subieron fotos sin portada (Daiana y quien
-- venga sin este fix). Marca la más antigua de cada una.
UPDATE photos p
SET es_portada = true
WHERE p.id = (
  SELECT p2.id FROM photos p2
  WHERE p2.escort_id = p.escort_id
  ORDER BY p2.orden ASC NULLS LAST, p2.id ASC
  LIMIT 1
)
AND NOT EXISTS (
  SELECT 1 FROM photos px
  WHERE px.escort_id = p.escort_id AND px.es_portada = true
);

-- Trigger: al insertar, si la escort aún no tiene portada, esta lo es.
CREATE OR REPLACE FUNCTION set_primera_foto_portada()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM photos
    WHERE escort_id = NEW.escort_id AND es_portada = true
  ) THEN
    NEW.es_portada := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_primera_foto_portada ON photos;
CREATE TRIGGER trg_primera_foto_portada
BEFORE INSERT ON photos
FOR EACH ROW
EXECUTE FUNCTION set_primera_foto_portada();
