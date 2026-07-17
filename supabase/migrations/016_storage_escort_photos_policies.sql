-- ── Policies del bucket escort-photos ──────────────────────────────
--
-- El bucket existe y es público (lectura abierta: las fotos se muestran en
-- el sitio), pero NO tenía ninguna policy de escritura. Storage tiene RLS
-- activo por default → sin policy de INSERT todo upload se rechazaba con
-- "new row violates row-level security policy". Recién saltó cuando la
-- primera escort intentó subir una foto.
--
-- El bucket y la tabla photos se habían creado a mano en el panel y nunca
-- quedaron versionados; esto los deja en migración para no volver a perderlos.
--
-- Modelo de permisos: upload.js guarda cada archivo como `<escort_id>/<ts>.ext`,
-- así la PRIMERA carpeta del path es el id del escort. Una escort solo puede
-- escribir/borrar dentro de SU carpeta: la comprobación ata esa carpeta
-- (storage.foldername(name))[1] al escort cuyo user_id = auth.uid().

-- Subir: solo dentro de la carpeta del propio escort.
CREATE POLICY "escort_photos_insert_own"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'escort-photos'
  AND (storage.foldername(name))[1] IN (
    SELECT e.id::text FROM escorts e WHERE e.user_id = auth.uid()
  )
);

-- Reemplazar/actualizar un objeto propio (upsert del mismo path).
CREATE POLICY "escort_photos_update_own"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'escort-photos'
  AND (storage.foldername(name))[1] IN (
    SELECT e.id::text FROM escorts e WHERE e.user_id = auth.uid()
  )
);

-- Borrar una foto propia.
CREATE POLICY "escort_photos_delete_own"
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'escort-photos'
  AND (storage.foldername(name))[1] IN (
    SELECT e.id::text FROM escorts e WHERE e.user_id = auth.uid()
  )
);
