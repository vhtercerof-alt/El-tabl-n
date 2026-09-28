// Envía avisos (notificaciones push) del tablón.
//
// La página llama a POST /api/notificar con { tipo, id } y la sesión del
// usuario. El servidor decide SIEMPRE a quién avisar y qué texto enviar;
// la página nunca puede mandar mensajes arbitrarios.
//
//   tarea_nueva        · solo owner/admin · avisa a todos (incluido quien publica)
//   entrega_nueva      · solo el autor de la entrega · avisa a owner/admin
//   entrega_calificada · solo owner/admin · avisa al autor de la entrega
//   prueba             · cualquiera · avisa SOLO a sus propios dispositivos
//
// Cada aviso se registra en tb_push_log para no repetirlo.
//
// Variables de entorno: ver api/_config.js.
import {
  CFG, prepararVapid, recortar, db, usuarioDeLaSesion, primeraVez, suscripciones, enviar,
} from "./_push.js";

const TIPOS = new Set(["tarea_nueva", "entrega_nueva", "entrega_calificada", "prueba"]);
const ID_VALIDO = /^[0-9A-Za-z-]{1,64}$/;

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "POST") {
    return res.status(405).json({ error: "Método no permitido." });
  }
  if (!CFG.listo) {
    return res.status(503).json({ error: "Avisos no configurados en Vercel.", problemas: CFG.problemas });
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

    prepararVapid();

    let destinos, mensaje, clave;

    if (tipo === "prueba") {
      // Solo a los dispositivos de quien lo pide; como mucho uno por minuto.
      clave = `prueba:${uid}:${Math.floor(Date.now() / 60000)}`;
      destinos = await suscripciones([uid]);
      if (!destinos.length) {
        return res.status(404).json({ error: "Este usuario no tiene dispositivos con avisos activados." });
      }
      mensaje = { titulo: "🔔 Aviso de prueba", cuerpo: "¡Los avisos de El Tablón funcionan en este dispositivo!", url: "/" };
      if (!(await primeraVez(clave))) {
        return res.status(429).json({ error: "Espera un minuto antes de otra prueba." });
      }
      const enviados = await enviar(destinos, mensaje, null);
      return res.status(enviados ? 200 : 502).json(enviados
        ? { enviados }
        : { error: "El servicio de avisos del navegador rechazó el envío. Desactiva y vuelve a activar los avisos." });
    } else if (tipo === "tarea_nueva") {
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
          url: "/?vista=entregas",
        };
      }
    }

    if (!(await primeraVez(clave))) {
      return res.status(200).json({ enviados: 0, repetido: true });
    }
    // En una tarea nueva también avisa a quien la publica (confirma que funcionó).
    const enviados = await enviar(destinos || [], mensaje, tipo === "tarea_nueva" ? null : uid);
    return res.status(200).json({ enviados });
  } catch (e) {
    console.error("[notificar]", e && e.message, e && e.detalle);
    const faltaTabla = e && /PGRST205|42P01|does not exist|schema cache/i.test(e.detalle || "");
    return res.status(500).json({
      error: faltaTabla
        ? "Falta ejecutar ACTIVAR-3-avisos.sql (y ACTIVAR-1-entregas.sql) en Supabase."
        : e && /Supabase 401|Supabase 403/.test(e.message)
          ? "La clave secreta de Supabase en Vercel no es válida."
          : "No se pudo enviar el aviso.",
    });
  }
}
