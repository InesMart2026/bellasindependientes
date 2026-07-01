CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE escorts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  nombre TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  categoria TEXT NOT NULL CHECK (categoria IN ('mujeres', 'hombres', 'trans')),
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

INSERT INTO storage.buckets (id, name, public) VALUES ('escort-photos', 'escort-photos', true);
INSERT INTO storage.buckets (id, name, public) VALUES ('verification-docs', 'verification-docs', false);
