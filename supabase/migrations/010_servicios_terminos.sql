-- ═══════════════════════════════════════════════════════════════════
-- 010 — Servicios como lista cerrada + versionado de términos +
--       reafirmación de responsabilidad por anuncio.
--
-- Tres problemas que se resuelven acá:
--
--  1. `servicios` era TEXT libre. El dashboard actualiza escorts con un
--     .update() directo desde el navegador, así que la validación en el
--     HTML no vale nada: con la consola abierta se escribe cualquier cosa.
--     Un servicio ilegal publicado en el sitio es riesgo de baja del
--     procesador de pago y del hosting. La whitelist se aplica en la DB.
--
--  2. `acuerdo_legal` era un booleano sin versión. Si mañana cambian los
--     términos, no hay forma de probar QUÉ texto aceptó cada escort ni de
--     forzar una re-aceptación. Se agrega versión + tabla de constancias.
--
--  3. Cada compra de horas/días publica un anuncio nuevo, pero la única
--     firma de responsabilidad era la del onboarding. Se registra una
--     reafirmación por cada pago, ligada al package contratado.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Whitelist de servicios ──────────────────────────────────────
-- Catálogo en tabla, no en un CHECK hardcodeado: agregar un servicio
-- nuevo es un INSERT, no una migración. `activo` permite retirar una
-- opción sin borrar los perfiles que ya la eligieron.
CREATE TABLE IF NOT EXISTS servicios_catalogo (
  slug   TEXT PRIMARY KEY,
  nombre TEXT NOT NULL,
  grupo  TEXT NOT NULL DEFAULT 'modalidad',
  orden  INTEGER NOT NULL DEFAULT 0,
  activo BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO servicios_catalogo (slug, nombre, grupo, orden) VALUES
  ('a-domicilio',       'A domicilio',          'modalidad', 10),
  ('con-lugar',         'Con lugar propio',     'modalidad', 20),
  ('hotel',             'Hotel',                'modalidad', 30),
  ('salidas',           'Salidas / eventos',    'modalidad', 40),
  ('videollamada',      'Videollamada',         'modalidad', 50),
  ('packs',             'Packs de fotos',       'modalidad', 60),
  ('chat',              'Chat',                 'modalidad', 70),
  ('masajes',           'Masajes',              'extras',    10),
  ('cenas',             'Acompañante a cenas',  'extras',    20),
  ('viajes',            'Viajes',               'extras',    30),
  ('despedidas',        'Despedidas',           'extras',    40)
ON CONFLICT (slug) DO NOTHING;

ALTER TABLE servicios_catalogo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "servicios_catalogo lectura pública" ON servicios_catalogo;
CREATE POLICY "servicios_catalogo lectura pública" ON servicios_catalogo
  FOR SELECT USING (activo = true);

-- ── 2. escorts.servicios pasa de TEXT libre a TEXT[] validado ──────
-- Se conserva la columna vieja como `servicios_legacy` en vez de borrarla:
-- es texto que las escorts escribieron y, si algo sale mal, se recupera.
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS servicios_legacy TEXT;

DO $$
BEGIN
  -- Solo migrar si `servicios` sigue siendo TEXT (evita re-correr en vano).
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'escorts' AND column_name = 'servicios'
      AND data_type = 'text'
  ) THEN
    UPDATE escorts SET servicios_legacy = servicios WHERE servicios IS NOT NULL;
    ALTER TABLE escorts DROP COLUMN servicios;
    ALTER TABLE escorts ADD COLUMN servicios TEXT[] NOT NULL DEFAULT '{}';
  END IF;
END $$;

-- El texto libre viejo NO se auto-mapea a la whitelist: mapear "masajes
-- eróticos" a `masajes` sería inventar una declaración que la escort no
-- hizo. Cada una vuelve a elegir sus servicios la próxima vez que edite.

-- ── 3. Trigger: rechazar servicios fuera de la whitelist ───────────
-- Esta es la defensa real. El HTML puede mentir; esto no.
CREATE OR REPLACE FUNCTION validate_servicios() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  invalido TEXT;
BEGIN
  IF NEW.servicios IS NULL THEN
    NEW.servicios := '{}';
    RETURN NEW;
  END IF;

  IF array_length(NEW.servicios, 1) > 11 THEN
    RAISE EXCEPTION 'Demasiados servicios seleccionados.';
  END IF;

  SELECT s INTO invalido
  FROM unnest(NEW.servicios) AS s
  WHERE s NOT IN (SELECT slug FROM servicios_catalogo WHERE activo = true)
  LIMIT 1;

  IF invalido IS NOT NULL THEN
    RAISE EXCEPTION 'Servicio no permitido: %', invalido;
  END IF;

  -- Sin duplicados: dos chips iguales en el perfil público.
  SELECT ARRAY(SELECT DISTINCT unnest(NEW.servicios)) INTO NEW.servicios;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_servicios ON escorts;
CREATE TRIGGER trg_validate_servicios
  BEFORE INSERT OR UPDATE OF servicios ON escorts
  FOR EACH ROW EXECUTE FUNCTION validate_servicios();

-- ── 4. Versionado de términos ──────────────────────────────────────
-- La versión vigente vive en una tabla, no hardcodeada en el HTML: cuando
-- cambien los términos, se inserta una fila nueva y todas las escorts que
-- firmaron una versión anterior quedan obligadas a re-aceptar.
CREATE TABLE IF NOT EXISTS terminos_versiones (
  version    TEXT PRIMARY KEY,
  texto      TEXT NOT NULL,
  vigente_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO terminos_versiones (version, texto) VALUES (
  '2026-07-13',
  'Declaro bajo juramento que soy mayor de 18 años, que los datos y las ' ||
  'imágenes que publico son propios y verídicos, y que soy la única ' ||
  'responsable del contenido de mi anuncio. Acepto los términos y ' ||
  'condiciones del sitio.'
) ON CONFLICT (version) DO NOTHING;

ALTER TABLE terminos_versiones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "terminos lectura pública" ON terminos_versiones;
CREATE POLICY "terminos lectura pública" ON terminos_versiones
  FOR SELECT USING (true);

-- Devuelve la versión vigente (la más reciente por vigente_at).
CREATE OR REPLACE FUNCTION terminos_vigentes()
RETURNS TABLE(version TEXT, texto TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT t.version, t.texto
  FROM terminos_versiones t
  ORDER BY t.vigente_at DESC
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION terminos_vigentes() TO anon, authenticated;

-- ── 5. Constancias de aceptación (append-only) ─────────────────────
-- Cada aceptación deja una fila inmutable con el texto exacto que se
-- mostró. Es la prueba que se exhibe si un anuncio termina judicializado:
-- no alcanza con "aceptó", hay que poder decir QUÉ aceptó y CUÁNDO.
--
-- `contexto` distingue las dos firmas:
--   'onboarding' → la del alta / re-aceptación por cambio de términos.
--   'anuncio'    → la reafirmación al contratar cada paquete.
CREATE TABLE IF NOT EXISTS acuerdos_aceptados (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  escort_id  UUID NOT NULL REFERENCES escorts(id) ON DELETE CASCADE,
  version    TEXT NOT NULL REFERENCES terminos_versiones(version),
  texto      TEXT NOT NULL,          -- copia congelada: si la versión se edita, esto no cambia
  contexto   TEXT NOT NULL CHECK (contexto IN ('onboarding', 'anuncio')),
  package_id UUID REFERENCES packages(id),  -- solo en contexto 'anuncio'
  ip         TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_acuerdos_escort ON acuerdos_aceptados(escort_id, created_at DESC);

ALTER TABLE acuerdos_aceptados ENABLE ROW LEVEL SECURITY;

-- La escort puede leer sus propias constancias. Nadie las escribe ni las
-- borra desde el cliente: solo entran por las RPC SECURITY DEFINER de abajo.
DROP POLICY IF EXISTS "acuerdos: la escort lee los suyos" ON acuerdos_aceptados;
CREATE POLICY "acuerdos: la escort lee los suyos" ON acuerdos_aceptados
  FOR SELECT USING (
    escort_id IN (SELECT id FROM escorts WHERE user_id = auth.uid())
  );

-- ── 6. Columna de versión firmada en escorts ───────────────────────
ALTER TABLE escorts ADD COLUMN IF NOT EXISTS acuerdo_legal_version TEXT;

-- Backfill: las que ya firmaron quedan asociadas a la versión inicial.
UPDATE escorts
   SET acuerdo_legal_version = '2026-07-13'
 WHERE acuerdo_legal = true AND acuerdo_legal_version IS NULL;

-- Y se les crea la constancia retroactiva, con la fecha real de su firma.
INSERT INTO acuerdos_aceptados (escort_id, version, texto, contexto, created_at)
SELECT e.id, '2026-07-13', t.texto, 'onboarding',
       COALESCE(e.acuerdo_legal_at, now())
  FROM escorts e
  CROSS JOIN (SELECT texto FROM terminos_versiones WHERE version = '2026-07-13') t
 WHERE e.acuerdo_legal = true
   AND NOT EXISTS (
     SELECT 1 FROM acuerdos_aceptados a
      WHERE a.escort_id = e.id AND a.contexto = 'onboarding'
   );

-- ── 7. Congelar la versión firmada para authenticated ──────────────
-- Mismo criterio que el consentimiento de fotos: la escort no puede
-- decirle a la DB "ya firmé la versión nueva" desde el navegador.
CREATE OR REPLACE FUNCTION guard_protected_columns() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- service_role bypassa RLS y corre con otro rol → se le permite todo.
  IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' THEN
    RETURN NEW;
  END IF;

  NEW.estado_verificacion    := OLD.estado_verificacion;
  NEW.activa                 := OLD.activa;
  NEW.visible_hasta          := OLD.visible_hasta;
  NEW.destacada              := OLD.destacada;
  NEW.bloqueada              := OLD.bloqueada;
  NEW.bloqueada_motivo       := OLD.bloqueada_motivo;
  NEW.bloqueada_at           := OLD.bloqueada_at;
  NEW.consentimiento_fotos   := OLD.consentimiento_fotos;
  NEW.consentimiento_at      := OLD.consentimiento_at;
  NEW.acuerdo_legal          := OLD.acuerdo_legal;
  NEW.acuerdo_legal_at       := OLD.acuerdo_legal_at;
  NEW.acuerdo_legal_version  := OLD.acuerdo_legal_version;
  RETURN NEW;
END;
$$;

-- ── 8. RPC: aceptar los términos vigentes (onboarding) ─────────────
-- Reemplaza al UPDATE directo que hacía verificacion.html. El cliente ya
-- no manda `acuerdo_legal_at`: la fecha y la versión las pone el servidor.
-- Se re-firma cada vez que cambia la versión vigente.
CREATE OR REPLACE FUNCTION accept_terms()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  uid       UUID;
  eid       UUID;
  ya        TEXT;
  v_version TEXT;
  v_texto   TEXT;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autenticado');
  END IF;

  SELECT id, acuerdo_legal_version INTO eid, ya
    FROM escorts WHERE user_id = uid;

  IF eid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'perfil inexistente');
  END IF;

  SELECT version, texto INTO v_version, v_texto FROM terminos_vigentes();

  -- Sin versión vigente no hay nada que firmar. Nunca debería pasar (la tabla
  -- viene seeded), pero firmar NULL dejaría una constancia sin contenido.
  IF v_version IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin terminos vigentes');
  END IF;

  -- Ya firmó la versión vigente → no duplicar la constancia.
  IF ya IS NOT DISTINCT FROM v_version THEN
    RETURN jsonb_build_object('ok', true, 'ya', true, 'version', v_version);
  END IF;

  INSERT INTO acuerdos_aceptados (escort_id, version, texto, contexto)
  VALUES (eid, v_version, v_texto, 'onboarding');

  UPDATE escorts
     SET acuerdo_legal = true,
         acuerdo_legal_at = now(),
         acuerdo_legal_version = v_version
   WHERE id = eid;

  RETURN jsonb_build_object('ok', true, 'version', v_version);
END;
$$;

GRANT EXECUTE ON FUNCTION accept_terms() TO authenticated;

-- ── 9. RPC: reafirmar responsabilidad al contratar un anuncio ──────
-- La llama crear-pago ANTES de generar la preferencia de MercadoPago. Si
-- la escort no reafirmó, no hay checkout. Deja constancia ligada al
-- paquete: por cada anuncio publicado hay una firma con fecha propia.
-- p_ip / p_user_agent los manda crear-pago (la Edge Function sí ve los headers
-- del request). No se aceptan desde el navegador: ahí serían inventables.
CREATE OR REPLACE FUNCTION accept_ad_terms(
  p_package_id UUID,
  p_ip         TEXT DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  uid       UUID;
  eid       UUID;
  acepto    BOOLEAN;
  firmada   TEXT;
  v_version TEXT;
  v_texto   TEXT;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autenticado');
  END IF;

  SELECT id, acuerdo_legal, acuerdo_legal_version INTO eid, acepto, firmada
    FROM escorts WHERE user_id = uid;

  IF eid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'perfil inexistente');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM packages WHERE id = p_package_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'paquete inexistente');
  END IF;

  SELECT version, texto INTO v_version, v_texto FROM terminos_vigentes();

  IF v_version IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin terminos vigentes');
  END IF;

  -- No se puede reafirmar por un anuncio sin haber firmado los términos
  -- vigentes primero: la reafirmación cuelga de ese acuerdo, no lo sustituye.
  -- Se exige la aceptación explícita, no solo que las versiones coincidan:
  -- si acuerdo_legal es false, la versión guardada no significa nada.
  IF acepto IS NOT TRUE OR firmada IS DISTINCT FROM v_version THEN
    RETURN jsonb_build_object('ok', false, 'error', 'terminos_desactualizados',
                              'version', v_version);
  END IF;

  INSERT INTO acuerdos_aceptados (escort_id, version, texto, contexto, package_id, ip, user_agent)
  VALUES (eid, v_version, v_texto, 'anuncio', p_package_id, p_ip, p_user_agent);

  RETURN jsonb_build_object('ok', true, 'version', v_version);
END;
$$;

GRANT EXECUTE ON FUNCTION accept_ad_terms(UUID, TEXT, TEXT) TO authenticated;

-- ── 10. get_my_profile: servicios TEXT[] + versión firmada ─────────
DROP FUNCTION IF EXISTS get_my_profile();
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT[], idiomas TEXT,
              provincia TEXT, localidad TEXT, acuerdo_legal BOOLEAN,
              acuerdo_legal_version TEXT, terminos_vigentes_version TEXT,
              estado_verificacion TEXT, bloqueada BOOLEAN, bloqueada_motivo TEXT,
              consentimiento_fotos BOOLEAN, consentimiento_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  key TEXT;
  uid UUID;
  v_vigente TEXT;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN RETURN; END IF;

  SELECT value INTO key FROM secrets WHERE name = 'enc_key';
  SELECT t.version INTO v_vigente FROM terminos_vigentes() t;

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello,
         e.servicios, e.idiomas,
         e.provincia, e.localidad, e.acuerdo_legal,
         e.acuerdo_legal_version, v_vigente,
         e.estado_verificacion, e.bloqueada, e.bloqueada_motivo,
         e.consentimiento_fotos, e.consentimiento_at
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

-- ── 11. get_escort_decrypted: servicios como TEXT[] ────────────────
-- Idéntica a la de 006 salvo el tipo de `servicios`. Se conservan el
-- nombre del parámetro (slug_param — el front lo pasa por nombre) y la
-- cláusula `OR auth.uid() = e.user_id`, que es la que deja a la escort
-- previsualizar su propio perfil aunque todavía no esté publicado.
DROP FUNCTION IF EXISTS get_escort_decrypted(TEXT);
CREATE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, visible_hasta TIMESTAMPTZ, created_at TIMESTAMPTZ,
              tarifa NUMERIC, zona TEXT, horario TEXT, nacionalidad TEXT, altura INTEGER,
              ojos TEXT, cabello TEXT, servicios TEXT[], idiomas TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.visible_hasta, e.created_at,
         e.tarifa, e.zona, e.horario, e.nacionalidad, e.altura, e.ojos, e.cabello,
         e.servicios, e.idiomas
  FROM escorts e
  WHERE e.slug = slug_param
    AND e.bloqueada = false
    AND ((e.activa = true AND e.visible_hasta >= now()) OR auth.uid() = e.user_id);
END;
$$;

GRANT EXECUTE ON FUNCTION get_escort_decrypted(TEXT) TO anon, authenticated;

-- ── 12. Catálogo público de servicios para el front ────────────────
-- El perfil público recibe slugs; necesita el nombre visible. Una RPC en
-- vez de exponer la tabla evita que el front dependa de la forma interna.
CREATE OR REPLACE FUNCTION get_servicios_catalogo()
RETURNS TABLE(slug TEXT, nombre TEXT, grupo TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT c.slug, c.nombre, c.grupo
  FROM servicios_catalogo c
  WHERE c.activo = true
  ORDER BY c.grupo DESC, c.orden;
$$;

GRANT EXECUTE ON FUNCTION get_servicios_catalogo() TO anon, authenticated;
