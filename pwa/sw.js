// Service worker de El Tablón: solo muestra avisos. No guarda la app en
// caché, así cada visita recibe siempre la última versión publicada.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let datos = {};
  try { datos = event.data ? event.data.json() : {}; } catch (e) { datos = {}; }
  const titulo = String(datos.titulo || "El Tablón").slice(0, 80);
  const url = typeof datos.url === "string" && datos.url.startsWith("/") ? datos.url : "/";
  event.waitUntil(self.registration.showNotification(titulo, {
    body: String(datos.cuerpo || "").slice(0, 160),
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    lang: "es",
    data: { url },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const destino = new URL(event.notification.data && event.notification.data.url || "/", self.location.origin).href;
  event.waitUntil((async () => {
    const ventanas = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const v of ventanas) {
      if (new URL(v.url).origin === self.location.origin) {
        await v.focus();
        return v.navigate(destino);
      }
    }
    return self.clients.openWindow(destino);
  })());
});
