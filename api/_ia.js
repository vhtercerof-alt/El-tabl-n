// Funciones compartidas de las herramientas con IA (Profesor de lengua y
// Voleibol). Usan la API de Google Gemini. La clave vive SOLO en Vercel
// (GEMINI_API_KEY) y nunca llega al navegador.
//
// Variables (Vercel → Settings → Environment Variables):
//   GEMINI_API_KEY      · obligatoria (Google AI Studio → Get API key)
//   GEMINI_MODEL        · opcional; por defecto "gemini-flash-latest"
//   IA_LIMITE_LENGUA    · revisiones de texto por estudiante y día (15)
//   IA_LIMITE_VOLEIBOL  · análisis por persona con permiso y día (10)
//   IA_LIMITE_STAFF     · usos por día para owner/admin, por herramienta (40)
import { CFG, db, usuarioDeLaSesion } from "./_push.js";

const API = "https://generativelanguage.googleapis.com/v1beta/models/";

export function modelo() {
  const m = String(process.env.GEMINI_MODEL || "").trim();
  return /^[a-z0-9][a-z0-9.\-]{1,63}$/i.test(m) ? m : "gemini-flash-latest";
}

export function problemasIA() {
  const p = [];
  if (!String(process.env.GEMINI_API_KEY || "").trim()) p.push("Falta GEMINI_API_KEY en Vercel.");
  if (!CFG.supabaseUrl || !CFG.anonKey) p.push("Falta SUPABASE_URL o SUPABASE_ANON_KEY en Vercel.");
  if (!CFG.serviceKey) p.push("Falta la clave secreta de Supabase (SUPABASE_SERVICE_ROLE_KEY).");
  return p;
}

export class ErrorIA extends Error {
  constructor(status, mensaje) {
    super(mensaje);
    this.status = status;
    this.publico = mensaje;
  }
}

const esperar = (ms) => new Promise((r) => setTimeout(r, ms));
const BLOQUEOS = new Set(["SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "IMAGE_SAFETY"]);

function errorDeGemini(status, cuerpo) {
  const e = (cuerpo && cuerpo.error) || {};
  const texto = `${e.status || ""} ${e.message || ""}`;
  if (/API[_ ]KEY|api key/i.test(texto) || status === 401 || status === 403) {
    return new ErrorIA(503, "La clave de IA (GEMINI_API_KEY) no es válida. Avísale al owner.");
  }
  if (status === 404) return new ErrorIA(503, `El modelo de IA «${modelo()}» no está disponible. Revisa GEMINI_MODEL en Vercel.`);
  if (status === 429) return new ErrorIA(429, "Se agotó la cuota de la IA por ahora. Intenta de nuevo en unos minutos.");
  if (status >= 500) return new ErrorIA(502, "La IA de Google no respondió. Intenta de nuevo.");
  return new ErrorIA(502, "La IA no pudo procesar esta solicitud.");
}

// Llama a Gemini. Devuelve { texto, fuentes, consultas }.
//   esquema: JSON Schema de la respuesta (salida JSON validada por la API)
//   buscar:  true para usar la búsqueda de Google (grounding)
export async function gemini({ sistema, mensaje, esquema, buscar, maxTokens = 32768, plazo = 120000 }) {
  const config = { maxOutputTokens: maxTokens };
  if (esquema) {
    config.responseMimeType = "application/json";
    config.responseJsonSchema = esquema;
  }
  const cuerpo = {
    systemInstruction: { parts: [{ text: sistema }] },
    contents: [{ role: "user", parts: [{ text: mensaje }] }],
    generationConfig: config,
  };
  if (buscar) cuerpo.tools = [{ google_search: {} }];

  const fin = Date.now() + plazo;
  let datos = null;
  for (let intento = 0; intento < 2; intento++) {
    const resta = fin - Date.now();
    if (resta < 5000) throw new ErrorIA(504, "La IA tardó demasiado. Intenta de nuevo.");
    let r;
    try {
      r = await fetch(API + encodeURIComponent(modelo()) + ":generateContent", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-goog-api-key": String(process.env.GEMINI_API_KEY).trim() },
        body: JSON.stringify(cuerpo),
        signal: AbortSignal.timeout(resta),
      });
    } catch (e) {
      if (e && (e.name === "TimeoutError" || e.name === "AbortError")) throw new ErrorIA(504, "La IA tardó demasiado. Intenta de nuevo.");
      if (intento === 0) { await esperar(1500); continue; }
      throw new ErrorIA(502, "No se pudo conectar con la IA. Intenta de nuevo.");
    }
    const json = await r.json().catch(() => null);
    if (r.ok) { datos = json; break; }
    // Un reintento corto si el servicio está saturado.
    if ((r.status === 429 || r.status >= 500) && intento === 0) { await esperar(2500); continue; }
    console.error("[gemini]", r.status, json && json.error && json.error.message);
    throw errorDeGemini(r.status, json);
  }

  const cand = datos && Array.isArray(datos.candidates) ? datos.candidates[0] : null;
  if (!cand) {
    throw new ErrorIA(502, datos && datos.promptFeedback && datos.promptFeedback.blockReason
      ? "La IA no quiso procesar este contenido. Revísalo e intenta de nuevo."
      : "La IA no devolvió respuesta. Intenta de nuevo.");
  }
  if (BLOQUEOS.has(cand.finishReason)) throw new ErrorIA(502, "La IA no quiso responder a este contenido. Revísalo e intenta de nuevo.");
  if (cand.finishReason === "MAX_TOKENS") throw new ErrorIA(502, "La respuesta de la IA quedó incompleta. Intenta con un texto más corto.");
  const partes = (cand.content && Array.isArray(cand.content.parts)) ? cand.content.parts : [];
  const texto = partes.filter((p) => typeof p.text === "string" && !p.thought).map((p) => p.text).join("");
  const meta = cand.groundingMetadata || {};
  const fuentes = [];
  (Array.isArray(meta.groundingChunks) ? meta.groundingChunks : []).forEach((c) => {
    const w = c && c.web;
    if (w && /^https:\/\//.test(String(w.uri || "")) && !fuentes.some((f) => f.url === w.uri)) {
      fuentes.push({ titulo: String(w.title || "").slice(0, 200), url: String(w.uri).slice(0, 2000) });
    }
  });
  return { texto, fuentes, consultas: Array.isArray(meta.webSearchQueries) ? meta.webSearchQueries.slice(0, 10) : [] };
}

// Lee la respuesta JSON de Gemini (a veces llega envuelta en ```json).
export function leerJSON(texto) {
  const t = String(texto || "").trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try { return JSON.parse(t); } catch (e) { return null; }
}

function entero(valor, porDefecto) {
  const n = parseInt(valor, 10);
  return Number.isFinite(n) && n >= 0 && n <= 1000 ? n : porDefecto;
}

const LIMITES = {
  lengua: () => entero(process.env.IA_LIMITE_LENGUA, 15),
  voleibol: () => entero(process.env.IA_LIMITE_VOLEIBOL, 10),
};

// Día en Nicaragua (UTC-6, sin horario de verano).
function hoyNicaragua() {
  return new Date(Date.now() - 6 * 3600 * 1000).toISOString().slice(0, 10);
}

// ¿Tiene el usuario un rol con este permiso? (tabla tb_permisos_rol)
export async function tienePermiso(uid, permiso) {
  const mios = await db(`member_roles?user_id=eq.${uid}&select=role_id`);
  const ids = (mios || []).map((m) => String(m.role_id));
  if (!ids.length) return false;
  const con = await db(`tb_permisos_rol?permiso=eq.${encodeURIComponent(permiso)}&select=role_id`);
  return (con || []).some((p) => ids.includes(String(p.role_id)));
}

// Comprueba la sesión y el límite diario. Devuelve { uid, perfil, usados, limite }
// o { status, error } si no puede usar la herramienta.
export async function autorizar(req, herramienta, opciones = {}) {
  const auth = String(req.headers.authorization || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || token.length > 4096) return { status: 401, error: "Inicia sesión para usar esta herramienta." };
  const uid = await usuarioDeLaSesion(token);
  if (!uid) return { status: 401, error: "Tu sesión expiró. Vuelve a iniciar sesión." };
  const [perfil] = await db(`profiles?id=eq.${uid}&select=id,role,display_name`);
  if (!perfil) return { status: 403, error: "Perfil no encontrado." };
  if (opciones.permiso && perfil.role !== "owner") {
    let permitido = false;
    try {
      permitido = await tienePermiso(uid, opciones.permiso);
    } catch (e) {
      permitido = false; // sin la tabla de permisos, solo el owner
    }
    if (!permitido) return { status: 403, error: "No tienes permiso para usar esta herramienta. Pídeselo al owner." };
  }
  const esStaff = perfil.role === "owner" || perfil.role === "admin";
  const limite = esStaff ? entero(process.env.IA_LIMITE_STAFF, 40) : LIMITES[herramienta]();
  const prefijo = `ia:${herramienta}:${uid}:${hoyNicaragua()}:`;
  const usadas = await db(`tb_push_log?clave=like.${encodeURIComponent(prefijo + "*")}&select=clave&limit=1100`);
  return { uid, perfil, prefijo, usados: (usadas || []).length, limite };
}

// Descuenta un uso del día. Devuelve false si ya no quedan.
export async function descontarUso(a) {
  for (let n = a.usados + 1; n <= a.limite; n++) {
    const filas = await db("tb_push_log?on_conflict=clave", {
      method: "POST",
      headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
      body: JSON.stringify({ clave: a.prefijo + n }),
    });
    if (Array.isArray(filas) && filas.length) {
      a.usados = n;
      return true;
    }
  }
  return false;
}

// Devuelve el uso si la IA falló (no se cobra un intento fallido).
export async function devolverUso(a) {
  if (!a || !a.usados) return;
  try {
    await db(`tb_push_log?clave=eq.${encodeURIComponent(a.prefijo + a.usados)}`, { method: "DELETE" });
    a.usados -= 1;
  } catch (e) { /* si falla, solo se pierde un uso */ }
}

// Texto del usuario: sin caracteres de control (salvo saltos de línea) y con largo máximo.
export function limpiar(valor, max) {
  return String(valor == null ? "" : valor)
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, " ")
    .slice(0, max);
}

export function errorIA(e) {
  if (e instanceof ErrorIA) return { status: e.status, error: e.publico };
  if (e && /PGRST205|42P01|does not exist|schema cache/i.test(e.detalle || "")) {
    return { status: 500, error: "Falta ejecutar ACTIVAR-3-avisos.sql en Supabase (lo usa el contador diario)." };
  }
  return { status: 500, error: "Error inesperado del servidor." };
}
