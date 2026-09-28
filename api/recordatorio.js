// Recordatorio diario (Vercel Cron, ver "crons" en vercel.json): si hay
// entregas por revisar, avisa al owner y a los admins. Solo lo puede
// ejecutar Vercel, que envía la cabecera Authorization: Bearer CRON_SECRET.
import { CFG, prepararVapid, db, primeraVez, suscripciones, enviar } from "./_push.js";

export default async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  const secreto = process.env.CRON_SECRET || "";
  if (!secreto || req.headers.authorization !== `Bearer ${secreto}`) {
    return res.status(401).json({ error: "No autorizado." });
  }
  if (!CFG.listo) {
    return res.status(503).json({ error: "Avisos no configurados.", problemas: CFG.problemas });
  }
  try {
    const pendientes = await db("tb_entregas?estado=eq.pendiente&select=id&limit=1000");
    const total = (pendientes || []).length;
    if (!total) return res.status(200).json({ pendientes: 0, enviados: 0 });
    const hoy = new Date().toISOString().slice(0, 10);
    if (!(await primeraVez(`recordatorio:${hoy}`))) {
      return res.status(200).json({ pendientes: total, enviados: 0, repetido: true });
    }
    prepararVapid();
    const staff = await db("profiles?role=in.(owner,admin)&select=id");
    const destinos = await suscripciones((staff || []).map((p) => p.id));
    const enviados = await enviar(destinos, {
      titulo: "📥 Entregas por revisar",
      cuerpo: total === 1 ? "Tienes 1 entrega esperando tu calificación." : `Tienes ${total} entregas esperando tu calificación.`,
      url: "/?vista=entregas",
    }, null);
    return res.status(200).json({ pendientes: total, enviados });
  } catch (e) {
    console.error("[recordatorio]", e && e.message, e && e.detalle);
    return res.status(500).json({ error: "No se pudo enviar el recordatorio." });
  }
}
