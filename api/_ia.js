// Funciones compartidas de las herramientas con IA (Profesor de lengua y
// Voleibol). La clave de Anthropic vive SOLO en Vercel (ANTHROPIC_API_KEY)
// y nunca llega al navegador.
//
// Variables (Vercel → Settings → Environment Variables):
//   ANTHROPIC_API_KEY   · obligatoria para usar las herramientas
//   IA_LIMITE_LENGUA    · análisis de texto por estudiante y día (10)
//   IA_LIMITE_VOLEIBOL  · alineaciones por estudiante y día (4)
//   IA_LIMITE_STAFF     · usos por día para owner/admin, por herramienta (40)
import Anthropic from "@anthropic-ai/sdk";
import { CFG, db, usuarioDeLaSesion } from "./_push.js";

export const MODELO = "claude-opus-5-5";
// Si el modelo principal se niega por sus filtros de seguridad, la API
// reintenta con el modelo alternativo que Anthropic recomienda.
export const BETAS = ["server-side-fallback-2026-07-01"];

let cliente = null;
export function clienteIA() {
  if (!cliente) cliente = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY, maxRetries: 2 });
  return cliente;
}

export function problemasIA() {
  const p = [];
  if (!String(process.env.ANTHROPIC_API_KEY || "").trim()) p.push("Falta ANTHROPIC_API_KEY en Vercel.");
  if (!CFG.supabaseUrl || !CFG.anonKey) p.push("Falta SUPABASE_URL o SUPABASE_ANON_KEY en Vercel.");
  if (!CFG.serviceKey) p.push("Falta la clave secreta de Supabase (SUPABASE_SERVICE_ROLE_KEY).");
  return p;
}

function entero(valor, porDefecto) {
  const n = parseInt(valor, 10);
  return Number.isFinite(n) && n >= 0 && n <= 1000 ? n : porDefecto;
}

const LIMITES = {
  lengua: () => entero(process.env.IA_LIMITE_LENGUA, 10),
  voleibol: () => entero(process.env.IA_LIMITE_VOLEIBOL, 4),
};

// Día en Nicaragua (UTC-6, sin horario de verano).
function hoyNicaragua() {
  return new Date(Date.now() - 6 * 3600 * 1000).toISOString().slice(0, 10);
}

// Comprueba la sesión y el límite diario. Devuelve { uid, perfil, usados, limite }
// o { status, error } si no puede usar la herramienta.
export async function autorizar(req, herramienta) {
  const auth = String(req.headers.authorization || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || token.length > 4096) return { status: 401, error: "Inicia sesión para usar esta herramienta." };
  const uid = await usuarioDeLaSesion(token);
  if (!uid) return { status: 401, error: "Tu sesión expiró. Vuelve a iniciar sesión." };
  const [perfil] = await db(`profiles?id=eq.${uid}&select=id,role,display_name`);
  if (!perfil) return { status: 403, error: "Perfil no encontrado." };
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
  if (e instanceof Anthropic.AuthenticationError || e instanceof Anthropic.PermissionDeniedError) {
    return { status: 503, error: "La clave de IA (ANTHROPIC_API_KEY) no es válida. Avísale al owner." };
  }
  if (e instanceof Anthropic.RateLimitError) {
    return { status: 429, error: "La IA está muy ocupada. Intenta de nuevo en un minuto." };
  }
  if (e instanceof Anthropic.BadRequestError) {
    const saldo = /credit|billing|balance/i.test(String(e.message || ""));
    return {
      status: saldo ? 503 : 502,
      error: saldo
        ? "La cuenta de IA se quedó sin saldo. Avísale al owner."
        : "La IA no pudo procesar esta solicitud.",
    };
  }
  if (e instanceof Anthropic.APIConnectionError || e instanceof Anthropic.InternalServerError) {
    return { status: 502, error: "No se pudo conectar con la IA. Intenta de nuevo." };
  }
  if (e instanceof Anthropic.APIError) {
    return { status: 502, error: "La IA respondió con un error. Intenta de nuevo." };
  }
  if (e && /PGRST205|42P01|does not exist|schema cache/i.test(e.detalle || "")) {
    return { status: 500, error: "Falta ejecutar ACTIVAR-3-avisos.sql en Supabase (lo usa el contador diario)." };
  }
  return { status: 500, error: "Error inesperado del servidor." };
}

// Revisa el motivo de parada antes de leer la respuesta.
export function motivoInvalido(resp) {
  if (resp.stop_reason === "refusal") return "La IA no quiso responder a este contenido. Revisa el texto e intenta de nuevo.";
  if (resp.stop_reason === "max_tokens") return "La respuesta de la IA quedó incompleta. Intenta con un texto más corto.";
  return "";
}
