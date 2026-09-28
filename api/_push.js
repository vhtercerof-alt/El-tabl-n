// Funciones compartidas para enviar avisos (usadas por notificar y recordatorio).
import webpush from "web-push";
import { configuracion } from "./_config.js";

export const CFG = configuracion();
const SUPABASE_URL = CFG.supabaseUrl;
const SUPABASE_ANON_KEY = CFG.anonKey;
const SUPABASE_SERVICE_ROLE_KEY = CFG.serviceKey;

export function prepararVapid() {
  webpush.setVapidDetails(CFG.vapidSubject, CFG.vapidPublic, CFG.vapidPrivate);
}

export function recortar(texto, max) {
  const t = String(texto || "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
}

// Consulta a la base con la clave de servicio (solo en el servidor).
export async function db(ruta, opciones = {}) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${ruta}`, {
    ...opciones,
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      // Las claves nuevas (sb_secret_…) no son JWT: van solo en "apikey".
      ...(SUPABASE_SERVICE_ROLE_KEY.startsWith("sb_secret_")
        ? {}
        : { Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}` }),
      "Content-Type": "application/json",
      ...(opciones.headers || {}),
    },
  });
  if (!r.ok) {
    const detalle = await r.text().catch(() => "");
    const e = new Error(`Supabase ${r.status}`);
    e.detalle = detalle.slice(0, 300);
    throw e;
  }
  const texto = await r.text();
  return texto ? JSON.parse(texto) : null;
}

export async function usuarioDeLaSesion(token) {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? u.id : null;
}

// Devuelve true solo la primera vez que se registra esta clave.
export async function primeraVez(clave) {
  const filas = await db("tb_push_log?on_conflict=clave", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
    body: JSON.stringify({ clave }),
  });
  return Array.isArray(filas) && filas.length > 0;
}

export async function suscripciones(filtroUsuarios) {
  const filtro = filtroUsuarios
    ? `&user_id=in.(${filtroUsuarios.join(",")})`
    : "";
  const filas = await db(`tb_push_suscripciones?select=id,user_id,endpoint,p256dh,auth${filtro}&limit=2000`);
  // Doble control: aunque la consulta ya filtra, nunca enviar a otros usuarios.
  if (!filtroUsuarios) return filas || [];
  const permitidos = new Set(filtroUsuarios);
  return (filas || []).filter((s) => permitidos.has(s.user_id));
}

export async function enviar(subs, mensaje, excluir) {
  const cuerpo = JSON.stringify(mensaje);
  const resultados = await Promise.allSettled(
    subs
      .filter((s) => s.user_id !== excluir)
      .map((s) =>
        webpush
          .sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            cuerpo,
            { TTL: 86400, urgency: "normal" }
          )
          .catch(async (e) => {
            // El dispositivo ya no existe o retiró el permiso: se limpia.
            if (e && (e.statusCode === 404 || e.statusCode === 410)) {
              await db(`tb_push_suscripciones?id=eq.${s.id}`, { method: "DELETE" });
            }
            throw e;
          })
      )
  );
  return resultados.filter((r) => r.status === "fulfilled").length;
}

