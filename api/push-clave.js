// Devuelve la clave PÚBLICA de avisos (VAPID) y si el servidor está listo.
// No expone ningún secreto; solo nombres de ajustes que faltan, para poder
// diagnosticar desde la app.
import { configuracion } from "./_config.js";

export default function handler(req, res) {
  const cfg = configuracion();
  res.setHeader("Cache-Control", "no-store");
  if (!cfg.vapidPublic || cfg.problemas.some((p) => p.startsWith("VAPID_PUBLIC_KEY"))) {
    return res.status(503).json({ error: "Avisos no configurados en Vercel.", problemas: cfg.problemas });
  }
  return res.status(200).json({ clave: cfg.vapidPublic, listo: cfg.listo, problemas: cfg.problemas });
}
