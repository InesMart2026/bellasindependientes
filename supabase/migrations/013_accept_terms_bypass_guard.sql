-- ─────────────────────────────────────────────────────────────
-- 013 · accept_terms puede escribir la versión firmada
-- ─────────────────────────────────────────────────────────────
-- El trigger guard_protected_columns (010) congela acuerdo_legal_version
-- para todo lo que no sea service_role. Pero accept_terms() corre como
-- SECURITY DEFINER con el JWT de la escort (rol authenticated), así que el
-- trigger le revertía el UPDATE: la columna quedaba en NULL aunque la firma
-- se registrara en acuerdos_aceptados.
--
-- Consecuencia: crear-kyc veía acuerdo_legal_version = NULL, no coincidía con
-- la versión vigente y cortaba con "debés aceptar el acuerdo legal vigente
-- primero" — aunque ella acababa de aceptarlo.
--
-- Fix: accept_terms marca un flag de sesión (app.bypass_guard) antes de su
-- UPDATE, y el trigger lo respeta. Solo las RPC confiables SECURITY DEFINER
-- pueden prenderlo; desde el navegador el flag nunca está seteado, así que las
-- columnas siguen congeladas para el cliente. SET LOCAL lo limita a la
-- transacción: al terminar la RPC, el bypass desaparece.

-- ── 1. El trigger reconoce el bypass de las RPC confiables ─────────
CREATE OR REPLACE FUNCTION guard_protected_columns() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  -- service_role bypassa RLS y corre con otro rol → se le permite todo.
  IF current_setting('request.jwt.claims', true)::jsonb->>'role' = 'service_role' THEN
    RETURN NEW;
  END IF;

  -- Las RPC SECURITY DEFINER confiables (accept_terms) prenden este flag
  -- por transacción antes de tocar las columnas congeladas. El navegador
  -- no puede setearlo: no ejecuta esas funciones ni tiene SET a mano.
  IF current_setting('app.bypass_guard', true) = 'on' THEN
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

-- ── 2. accept_terms prende el bypass antes de escribir la firma ────
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

  IF v_version IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin terminos vigentes');
  END IF;

  -- Ya firmó la versión vigente → no duplicar la constancia.
  IF ya IS NOT DISTINCT FROM v_version THEN
    RETURN jsonb_build_object('ok', true, 'ya', true, 'version', v_version);
  END IF;

  INSERT INTO acuerdos_aceptados (escort_id, version, texto, contexto)
  VALUES (eid, v_version, v_texto, 'onboarding');

  -- Habilita el UPDATE de las columnas congeladas solo dentro de esta
  -- transacción: el trigger guard_protected_columns lo respeta arriba.
  PERFORM set_config('app.bypass_guard', 'on', true);

  UPDATE escorts
     SET acuerdo_legal = true,
         acuerdo_legal_at = now(),
         acuerdo_legal_version = v_version
   WHERE id = eid;

  RETURN jsonb_build_object('ok', true, 'version', v_version);
END;
$$;

GRANT EXECUTE ON FUNCTION accept_terms() TO authenticated;
