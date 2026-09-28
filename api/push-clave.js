// Devuelve la clave PÚBLICA de avisos (VAPID). No es secreta: el navegador
// la necesita para suscribirse. La privada nunca sale del servidor.
export default function handler(req, res) {
  const clave = process.env.VAPID_PUBLIC_KEY || "";
  res.setHeader("Cache-Control", "public, max-age=3600");
  if (!clave) {
    return res.status(503).json({ error: "Avisos no configurados en Vercel." });
  }
  return res.status(200).json({ clave });
}
