// Configuración compartida de los avisos. Los archivos de api/ que empiezan
// con "_" no son rutas públicas en Vercel.
//
// Variables (Vercel → Settings → Environment Variables):
//   SUPABASE_URL, SUPABASE_ANON_KEY
//   SUPABASE_SERVICE_ROLE_KEY (también se acepta SUPABASE_SECRET_KEY o
//     PRIVATE_KEY, pero SOLO si su valor es de verdad una clave secreta
//     de Supabase)
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
function rolDeJwt(valor) {
  try {
    const partes = String(valor).split(".");
    if (partes.length !== 3) return null;
    return JSON.parse(Buffer.from(partes[1], "base64url").toString("utf8")).role || null;
  } catch (e) {
    return null;
  }
}

function esClaveSecretaSupabase(valor) {
  const v = String(valor || "").trim();
  return v.startsWith("sb_secret_") || rolDeJwt(v) === "service_role";
}

function claveServicio() {
  const candidatas = [
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    process.env.SUPABASE_SECRET_KEY,
    process.env.PRIVATE_KEY,
  ];
  const valida = candidatas.find(esClaveSecretaSupabase);
  return valida ? valida.trim() : "";
}

function base64urlBytes(valor) {
  try {
    return Buffer.from(String(valor || "").trim(), "base64url").length;
  } catch (e) {
    return 0;
  }
}

export function configuracion() {
  const e = process.env;
  const cfg = {
    supabaseUrl: String(e.SUPABASE_URL || "").trim().replace(/\/$/, ""),
    anonKey: String(e.SUPABASE_ANON_KEY || "").trim(),
    serviceKey: claveServicio(),
    vapidPublic: String(e.VAPID_PUBLIC_KEY || "").trim(),
    vapidPrivate: String(e.VAPID_PRIVATE_KEY || "").trim(),
    vapidSubject: String(e.VAPID_SUBJECT || "").trim(),
  };
  const problemas = [];
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(cfg.supabaseUrl)) problemas.push("SUPABASE_URL falta o no es válida.");
  if (rolDeJwt(cfg.anonKey) !== "anon" && !cfg.anonKey.startsWith("sb_publishable_")) problemas.push("SUPABASE_ANON_KEY falta o no es la clave pública de Supabase.");
  if (!cfg.serviceKey) problemas.push("Falta la clave secreta de Supabase (SUPABASE_SERVICE_ROLE_KEY).");
  if (base64urlBytes(cfg.vapidPublic) !== 65) problemas.push("VAPID_PUBLIC_KEY falta o no es válida.");
  if (base64urlBytes(cfg.vapidPrivate) !== 32) problemas.push("VAPID_PRIVATE_KEY falta o no es válida (debe ser la pareja de VAPID_PUBLIC_KEY).");
  if (!/^(mailto:|https:\/\/)/.test(cfg.vapidSubject)) cfg.vapidSubject = "mailto:avisos@example.invalid";
  cfg.problemas = problemas;
  cfg.listo = problemas.length === 0;
  return cfg;
}
