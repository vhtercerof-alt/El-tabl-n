// Envía avisos (notificaciones push) del tablón.
//
// La página llama a POST /api/notificar con { tipo, id } y la sesión del
// usuario. El servidor decide SIEMPRE a quién avisar y qué texto enviar;
// la página nunca puede mandar mensajes arbitrarios.
//
//   tarea_nueva        · solo owner/admin · avisa a todos
//   entrega_nueva      · solo el autor de la entrega · avisa a owner/admin
//   entrega_calificada · solo owner/admin · avisa al autor de la entrega
//
// Cada aviso se registra en tb_push_log para no repetirlo.
//
// Variables de entorno (Vercel → Settings → Environment Variables):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY,
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:tu@correo)
import webpush from "web-push";

const {
  SUPABASE_URL,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY,
  VAPID_SUBJECT,
} = process.env;

const TIPOS = new Set(["tarea_nueva", "entrega_nueva", "entrega_calificada"]);
const ID_VALIDO = /^[0-9A-Za-z-]{1,64}$/;

function recortar(texto, max) {
  const t = String(texto || "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
}

// Consulta a la base con la clave de servicio (solo en el servidor).
async function db(ruta, opciones = {}) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${ruta}`, {
    ...opciones,
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
      ...(opciones.headers || {}),
    },
  });
  if (!r.ok) {
    throw new Error(`Supabase ${r.status}`);
  }
  const texto = await r.text();
  return texto ? JSON.parse(texto) : null;
}

async function usuarioDeLaSesion(token) {
  const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${token}` },
  });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? u.id : null;
}

// Devuelve true solo la primera vez que se registra esta clave.
async function primeraVez(clave) {
  const filas = await db("tb_push_log?on_conflict=clave", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates,return=representation" },
    body: JSON.stringify({ clave }),
  });
  return Array.isArray(filas) && filas.length > 0;
}

async function suscripciones(filtroUsuarios) {
  const filtro = filtroUsuarios
    ? `&user_id=in.(${filtroUsuarios.join(",")})`
    : "";
  return db(`tb_push_suscripciones?select=id,user_id,endpoint,p256dh,auth${filtro}&limit=2000`);
}

async function enviar(subs, mensaje, excluir) {
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

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Método no permitido." });
  }
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY ||
      !VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
    return res.status(503).json({ error: "Avisos no configurados en Vercel." });
  }

  const auth = String(req.headers.authorization || "");
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token || token.length > 4096) {
    return res.status(401).json({ error: "Sin sesión." });
  }

  const cuerpo = typeof req.body === "object" && req.body ? req.body : {};
  const tipo = String(cuerpo.tipo || "");
  const id = String(cuerpo.id || "");
  if (!TIPOS.has(tipo) || !ID_VALIDO.test(id)) {
    return res.status(400).json({ error: "Solicitud no válida." });
  }

  try {
    const uid = await usuarioDeLaSesion(token);
    if (!uid) return res.status(401).json({ error: "Sesión no válida." });

    const [yo] = await db(`profiles?id=eq.${uid}&select=id,role,display_name`);
    if (!yo) return res.status(403).json({ error: "Perfil no encontrado." });
    const esStaff = yo.role === "owner" || yo.role === "admin";

    webpush.setVapidDetails(
      VAPID_SUBJECT || "mailto:avisos@example.invalid",
      VAPID_PUBLIC_KEY,
      VAPID_PRIVATE_KEY
    );

    let destinos, mensaje, clave;

    if (tipo === "tarea_nueva") {
      if (!esStaff) return res.status(403).json({ error: "No autorizado." });
      const [tarea] = await db(`tasks?id=eq.${id}&select=id,title,subject,published`);
      if (!tarea || !tarea.published) return res.status(404).json({ error: "Tarea no publicada." });
      clave = `tarea_nueva:${tarea.id}`;
      destinos = await suscripciones(null);
      mensaje = {
        titulo: "📌 Nueva tarea en El Tablón",
        cuerpo: recortar(`${tarea.subject ? tarea.subject + ": " : ""}${tarea.title}`, 140),
        url: "/?vista=tasks",
      };
    } else {
      const [entrega] = await db(
        `tb_entregas?id=eq.${id}&select=id,task_id,user_id,estado,nota,updated_at,revisada_at`
      );
      if (!entrega) return res.status(404).json({ error: "Entrega no encontrada." });
      const [tarea] = await db(`tasks?id=eq.${entrega.task_id}&select=title`);
      const titulo = recortar(tarea ? tarea.title : "una tarea", 80);

      if (tipo === "entrega_nueva") {
        if (entrega.user_id !== uid) return res.status(403).json({ error: "No autorizado." });
        clave = `entrega_nueva:${entrega.id}:${entrega.updated_at}`;
        const staff = await db("profiles?role=in.(owner,admin)&select=id");
        destinos = await suscripciones(staff.map((p) => p.id));
        mensaje = {
          titulo: "📥 Nueva entrega para revisar",
          cuerpo: recortar(`${yo.display_name || "Un estudiante"} entregó «${titulo}»`, 140),
          url: "/?vista=entregas",
        };
      } else {
        if (!esStaff) return res.status(403).json({ error: "No autorizado." });
        if (entrega.estado === "pendiente") return res.status(409).json({ error: "Aún sin calificar." });
        clave = `entrega_calificada:${entrega.id}:${entrega.revisada_at}`;
        destinos = await suscripciones([entrega.user_id]);
        const aprobada = entrega.estado === "aprobada";
        mensaje = {
          titulo: aprobada ? "✅ ¡Tarea aprobada!" : "↩️ Tu entrega fue devuelta",
          cuerpo: recortar(
            aprobada
              ? `«${titulo}»${entrega.nota != null ? ` · Nota: ${entrega.nota}` : ""} · +1 cumplido`
              : `Revisa los comentarios de «${titulo}» y vuelve a entregar.`,
            140
          ),
          url: "/?vista=tasks",
        };
      }
    }

    if (!(await primeraVez(clave))) {
      return res.status(200).json({ enviados: 0, repetido: true });
    }
    const enviados = await enviar(destinos || [], mensaje, uid);
    return res.status(200).json({ enviados });
  } catch (e) {
    console.error("[notificar]", e && e.message);
    return res.status(500).json({ error: "No se pudo enviar el aviso." });
  }
}
