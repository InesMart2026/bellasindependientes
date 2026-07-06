CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE escorts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  nombre TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  categoria TEXT NOT NULL CHECK (categoria IN ('mujeres', 'hombres', 'trans', 'masajistas')),
  edad INTEGER,
  ubicacion TEXT,
  bio TEXT,
  instagram TEXT,
  whatsapp TEXT,
  activa BOOLEAN DEFAULT false,
  destacada BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE photos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  url TEXT NOT NULL,
  orden INTEGER DEFAULT 0,
  es_portada BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE plans (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  nombre TEXT NOT NULL,
  precio NUMERIC NOT NULL,
  duracion_dias INTEGER NOT NULL,
  max_fotos INTEGER NOT NULL
);

CREATE TABLE subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  plan_id UUID REFERENCES plans(id) NOT NULL,
  inicio DATE DEFAULT CURRENT_DATE,
  fin DATE NOT NULL,
  paga BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE escorts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "escorts_select_public" ON escorts
  FOR SELECT USING (activa = true OR auth.uid() = user_id);

CREATE POLICY "escorts_insert_own" ON escorts
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "escorts_update_own" ON escorts
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "escorts_delete_own" ON escorts
  FOR DELETE USING (auth.uid() = user_id);

ALTER TABLE photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "photos_select_public" ON photos
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM escorts WHERE escorts.id = photos.escort_id AND escorts.activa = true)
    OR auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id)
  );

CREATE POLICY "photos_insert_own" ON photos
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id));

CREATE POLICY "photos_delete_own" ON photos
  FOR DELETE USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = photos.escort_id));

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "subscriptions_select_own" ON subscriptions
  FOR SELECT USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = subscriptions.escort_id));

CREATE POLICY "subscriptions_insert_own" ON subscriptions
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM escorts WHERE id = subscriptions.escort_id));

-- Verification photos (DNI)
CREATE TABLE verification_photos (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  escort_id UUID REFERENCES escorts(id) ON DELETE CASCADE NOT NULL,
  url TEXT NOT NULL,
  verified BOOLEAN DEFAULT false,
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE verification_photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "verif_insert_own" ON verification_photos
  FOR INSERT WITH CHECK (auth.uid() = (SELECT user_id FROM escorts WHERE id = escort_id));

CREATE POLICY "verif_select_own" ON verification_photos
  FOR SELECT USING (auth.uid() = (SELECT user_id FROM escorts WHERE id = escort_id));

-- Encriptación automática de datos sensibles
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE secrets (
  name TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO secrets (name, value) VALUES ('enc_key', encode(gen_random_bytes(32), 'hex'));

ALTER TABLE secrets ENABLE ROW LEVEL SECURITY;

-- Solo funciones internas pueden leer secrets
CREATE POLICY "secrets_no_access" ON secrets
  FOR SELECT USING (false);

-- Encripta instagram y whatsapp antes de guardar
CREATE FUNCTION auto_encrypt_sensitive() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  IF NEW.instagram IS NOT NULL AND NEW.instagram !~ '\\x' THEN
    NEW.instagram = pgp_sym_encrypt(NEW.instagram, key);
  END IF;

  IF NEW.whatsapp IS NOT NULL AND NEW.whatsapp !~ '\\x' THEN
    NEW.whatsapp = pgp_sym_encrypt(NEW.whatsapp, key);
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER encrypt_sensitive_trigger
  BEFORE INSERT OR UPDATE OF instagram, whatsapp ON escorts
  FOR EACH ROW EXECUTE FUNCTION auto_encrypt_sensitive();

-- Desencripta al leer el perfil público
CREATE FUNCTION get_escort_decrypted(slug_param TEXT)
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  key TEXT;
BEGIN
  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.created_at
  FROM escorts e
  WHERE e.slug = slug_param AND (e.activa = true OR auth.uid() = e.user_id);
END;
$$;

-- Desencripta para el dashboard (solo el dueño)
CREATE FUNCTION get_my_profile()
RETURNS TABLE(id UUID, user_id UUID, nombre TEXT, slug TEXT, categoria TEXT,
              edad INTEGER, ubicacion TEXT, bio TEXT, instagram TEXT, whatsapp TEXT,
              activa BOOLEAN, destacada BOOLEAN, created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  key TEXT;
  uid UUID;
BEGIN
  uid := auth.uid();
  IF uid IS NULL THEN RETURN; END IF;

  SELECT value INTO key FROM secrets WHERE name = 'enc_key';

  RETURN QUERY
  SELECT e.id, e.user_id, e.nombre, e.slug, e.categoria, e.edad, e.ubicacion, e.bio,
         CASE WHEN e.instagram ~ '\\x' THEN pgp_sym_decrypt(e.instagram::bytea, key) ELSE e.instagram END,
         CASE WHEN e.whatsapp ~ '\\x' THEN pgp_sym_decrypt(e.whatsapp::bytea, key) ELSE e.whatsapp END,
         e.activa, e.destacada, e.created_at
  FROM escorts e
  WHERE e.user_id = uid;
END;
$$;

-- Tope duro a nivel servidor: solo imágenes JPG/PNG/WebP, máximo 5MB.
-- El JS del cliente valida lo mismo, pero esta es la barrera que no se saltea.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'escort-photos', 'escort-photos', true,
  5242880,                                        -- 5 MB en bytes
  ARRAY['image/jpeg', 'image/png', 'image/webp']
);
INSERT INTO storage.buckets (id, name, public) VALUES ('verification-docs', 'verification-docs', false);
