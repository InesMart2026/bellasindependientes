-- 009 — Resolver el perfil denunciado aunque el denunciante no sepa el slug.
--
-- Problema real: el campo "Perfil denunciado" de denunciar.html es texto libre
-- ("Nombre o URL del perfil"). Quien entra directo escribe el nombre que ve
-- ("Romina") o pega la URL completa. submit_report buscaba `WHERE slug = ...`
-- exacto, no encontraba nada, y guardaba la denuncia con escort_id NULL.
-- Resultado: el panel admin no podía bloquear el perfil, porque no sabía cuál era.
--
-- Acá se resuelve el identificador de forma tolerante y se agrega una RPC para
-- ligar a mano las denuncias que ya quedaron huérfanas.

-- ── 1. Normalizar lo que escribió el denunciante ───────────────────
-- Acepta: "romina", "Romina", "/perfil.html?slug=romina",
-- "https://bellasindependientes.com/perfil.html?slug=romina".
-- Devuelve el escort.id o NULL si no hay match.
CREATE OR REPLACE FUNCTION resolve_reported_escort(input TEXT)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  cleaned TEXT;
  eid UUID;
BEGIN
  IF input IS NULL OR trim(input) = '' THEN
    RETURN NULL;
  END IF;

  cleaned := trim(input);

  -- Si pegaron una URL, quedarse con el valor del parámetro slug.
  IF cleaned ~* 'slug=' THEN
    cleaned := substring(cleaned from 'slug=([^&#\s]+)');
    cleaned := replace(cleaned, '%20', ' ');
  END IF;

  cleaned := trim(cleaned);

  -- a) slug exacto (case-insensitive: los slugs son minúscula, el input no).
  SELECT id INTO eid FROM escorts WHERE lower(slug) = lower(cleaned) LIMIT 1;
  IF eid IS NOT NULL THEN RETURN eid; END IF;

  -- b) nombre exacto, pero solo si es inequívoco: si hay dos "Romina" no
  --    adivinamos cuál — se deja NULL y lo liga el admin, que sí puede mirar
  --    el caso. Bloquear al perfil equivocado es peor que no bloquear.
  IF (SELECT count(*) FROM escorts WHERE lower(nombre) = lower(cleaned)) = 1 THEN
    SELECT id INTO eid FROM escorts WHERE lower(nombre) = lower(cleaned);
    RETURN eid;
  END IF;

  RETURN NULL;
END;
$$;

-- ── 2. submit_report ahora usa el resolvedor ───────────────────────
CREATE OR REPLACE FUNCTION submit_report(
  slug_param  TEXT,
  categoria_param TEXT,
  email_param TEXT,
  motivo_param TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  eid UUID;
  recientes INT;
BEGIN
  IF categoria_param NOT IN ('menores','trata','multicuenta','suplantacion','contenido','estafa','otro') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'categoria invalida');
  END IF;
  IF email_param IS NULL OR email_param !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'email invalido');
  END IF;
  IF motivo_param IS NULL OR length(trim(motivo_param)) < 10 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'motivo demasiado corto');
  END IF;
  IF length(motivo_param) > 4000 THEN
    motivo_param := left(motivo_param, 4000);
  END IF;

  -- Tolerante a nombre o URL, no solo al slug exacto. Puede quedar NULL: la
  -- denuncia se guarda igual (el admin la lee y la liga), nunca se descarta.
  eid := resolve_reported_escort(slug_param);

  SELECT count(*) INTO recientes
  FROM reports
  WHERE email = lower(email_param)
    AND slug = slug_param
    AND created_at > now() - interval '1 hour';

  IF recientes >= 3 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'demasiadas denuncias, intenta mas tarde');
  END IF;

  INSERT INTO reports (escort_id, slug, categoria, email, motivo)
  VALUES (eid, slug_param, categoria_param, lower(email_param), trim(motivo_param));

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION submit_report(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
-- resolve_reported_escort NO se expone: solo la usan las funciones de arriba.
REVOKE EXECUTE ON FUNCTION resolve_reported_escort(TEXT) FROM anon, authenticated;

-- ── 3. Ligar a mano una denuncia huérfana ──────────────────────────
-- Para las denuncias que ya entraron sin escort_id (y para los casos donde el
-- denunciante escribió algo ambiguo). Solo service_role: la llama la Edge
-- Function admin-bloquear con la clave de administración.
CREATE OR REPLACE FUNCTION link_report_to_escort(
  report_id_param UUID,
  slug_param TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  eid UUID;
BEGIN
  IF coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') <> 'service_role' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no autorizado');
  END IF;

  eid := resolve_reported_escort(slug_param);
  IF eid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no existe un perfil con ese slug o nombre');
  END IF;

  UPDATE reports
     SET escort_id = eid
   WHERE id = report_id_param
     AND estado IN ('nueva','en_revision');

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'denuncia inexistente o ya resuelta');
  END IF;

  RETURN jsonb_build_object('ok', true, 'escort_id', eid);
END;
$$;

REVOKE EXECUTE ON FUNCTION link_report_to_escort(UUID, TEXT) FROM anon, authenticated;

-- ── 4. Rescatar las denuncias huérfanas que ya están en la base ────
-- Re-resuelve las que quedaron sin perfil por el bug (ej: escribieron el nombre).
UPDATE reports r
   SET escort_id = resolve_reported_escort(r.slug)
 WHERE r.escort_id IS NULL
   AND r.slug IS NOT NULL
   AND r.estado IN ('nueva','en_revision')
   AND resolve_reported_escort(r.slug) IS NOT NULL;
