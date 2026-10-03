// Genera el sitio para Vercel a partir de index.html (la versión para Systeme.io).
// Separa el CSS y el JavaScript en archivos propios para poder aplicar una
// política de seguridad de contenido (CSP) estricta sin 'unsafe-inline' en scripts.
// Uso: node scripts/build.mjs   ->   crea la carpeta public/
import fs from "node:fs";

const fuente = fs.readFileSync("index.html", "utf8");

function unico(regex, nombre) {
  const todos = [...fuente.matchAll(regex)];
  if (todos.length !== 1) {
    throw new Error(`Se esperaba exactamente 1 bloque de ${nombre} y hay ${todos.length}.`);
  }
  return todos[0];
}

const libreria = unico(/<script src="https:\/\/cdn\.jsdelivr\.net[^>]*><\/script>/g, "librería Supabase")[0];
// La hoja de estilos principal es el primer <style> (puede haber otros
// <style id="…"> en el HTML y textos "<style>" dentro de dibujos SVG del código).
const estilo = /<style>([\s\S]*?)<\/style>/.exec(fuente);
if (!estilo) throw new Error("No se encontró el bloque <style> principal.");
const script = unico(/<script>([\s\S]*?)<\/script>/g, "<script> inline");

const inicioHtml = estilo.index + estilo[0].length;
// Bloques de código extra con id (por ejemplo, los de Halloween): se publican
// como archivos propios y se cargan en el mismo lugar, porque la CSP no
// permite código suelto dentro del HTML.
const extras = [];
function externalizar(html) {
  return html.replace(/<script id="([a-z0-9-]{1,40})">([\s\S]*?)<\/script>/g, (_, id, codigo) => {
    extras.push({ archivo: `${id}.js`, codigo });
    return `<script src="/${id}.js"></script>`;
  });
}
const cuerpo = externalizar(fuente.slice(inicioHtml, script.index).trim());
const finScript = script.index + script[0].length;
const despues = externalizar(fuente.slice(finScript).replace(/<\/body>\s*<\/html>\s*$/i, "").trim());
for (const parte of [cuerpo, despues]) {
  const sinPermitidos = parte.replace(/<script src="\/[a-z0-9-]{1,40}\.js"><\/script>/g, "");
  if (/<script|\son[a-z]+\s*=/i.test(sinPermitidos)) {
    throw new Error("El HTML contiene scripts o atributos on*= inline: la CSP los bloquearía.");
  }
}

const pagina = `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="same-origin">
<title>El Tablón</title>
<meta name="tb-plataforma" content="vercel">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="apple-touch-icon" href="/icon-192.png">
<meta name="theme-color" content="#0d1024">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="El Tablón">
${libreria}
<link rel="stylesheet" href="/styles.css">
<style>html,body{margin:0;background:#0d1024;}</style>
</head>
<body>
${cuerpo}
<script src="/app.js"></script>
${despues}
<!-- Estadísticas de Vercel (sin cookies). Actívalas en el panel: Analytics → Enable. -->
<script defer src="/_vercel/insights/script.js"></script>
</body>
</html>
`;

fs.rmSync("public", { recursive: true, force: true });
fs.mkdirSync("public");
fs.writeFileSync("public/index.html", pagina);
fs.writeFileSync("public/styles.css", estilo[1].trim() + "\n");
fs.writeFileSync("public/app.js", script[1].trim() + "\n");
for (const e of extras) {
  fs.writeFileSync("public/" + e.archivo, e.codigo.trim() + "\n");
}
fs.copyFileSync("assets/favicon.png", "public/favicon.png");
for (const f of ["sw.js", "manifest.webmanifest", "icon-192.png", "icon-512.png", "icon-maskable-512.png"]) {
  fs.copyFileSync("pwa/" + f, "public/" + f);
}
// Motor integrado del Profesor de lengua (diccionario y corrector, sin API).
fs.mkdirSync("public/motor");
for (const f of ["es.aff", "es.dic", "ortografia.js"]) {
  fs.copyFileSync("motor/" + f, "public/motor/" + f);
}
console.log("public/ generado:",
  ["index.html", "styles.css", "app.js"].map(f => `${f} ${(fs.statSync("public/" + f).size / 1024).toFixed(0)} KB`).join(", "));
