# Publicar El Tablón en Vercel

El repositorio ya está preparado. No hay que instalar nada ni tocar código.

## Cómo está organizado

| Archivo | Para qué sirve |
|---------|----------------|
| `index.html` | **El único archivo que editás.** Es la misma página que se pega en Systeme.io. |
| `scripts/build.mjs` | Vercel lo ejecuta en cada publicación. Separa `index.html` en `public/index.html`, `public/styles.css` y `public/app.js`. |
| `vercel.json` | Le dice a Vercel cómo construir el sitio y qué cabeceras de seguridad enviar. |
| `public/` | Se genera sola; no se sube al repositorio. |

Solo se publica la carpeta `public/`. El informe, el SQL y los scripts **no** quedan visibles en internet.

## Pasos (una sola vez)

1. **Crear la rama principal en GitHub.** Hoy el repositorio solo tiene la rama `claude/lucid-curie-14ahbh`. En GitHub:
   - abrí un Pull Request de esa rama hacia una rama `main` y hacé *Merge*;
   - o, en *Settings → Branches*, poné esa rama como predeterminada.

   Vercel publica en producción la rama predeterminada.
2. Entrá a <https://vercel.com> e iniciá sesión con tu cuenta de GitHub.
3. Hacé clic en **Add New… → Project** e importá el repositorio `vhtercerof-alt/El-tabl-n`. Si no aparece, usá *Adjust GitHub App Permissions* y dale acceso a ese repositorio.
4. En la pantalla de configuración:
   - **Framework Preset:** `Other`.
   - **Build Command / Output Directory:** dejalos como están. `vercel.json` ya los define (`node scripts/build.mjs` y `public`).
   - **Environment Variables:** ninguna. La URL y la clave pública de Supabase van en la página, y eso es normal.
5. Hacé clic en **Deploy**. En uno o dos minutos te da una dirección del tipo `https://el-tabl-n.vercel.app`.
6. En **Supabase → Authentication → URL Configuration**, poné esa dirección en **Site URL**.
7. Hacé la prueba rápida: iniciar sesión, girar una ruleta, abrir memes, publicar una noticia con foto y escuchar la mascota.

## Después

- **Actualizar la app:** editá `index.html`, hacé commit y push a `main`. Vercel vuelve a publicar solo.
- **Dominio propio (opcional):** en *Project → Settings → Domains*.
- **Vistas previas:** cada rama o Pull Request genera una dirección de prueba. Dejá activado *Deployment Protection → Vercel Authentication* (viene así por defecto) para que solo vos puedas verlas.
- **Si cambiás de proyecto Supabase:** además de `SUPABASE_URL` en `index.html`, cambiá la dirección `quppebdummixryqqcady.supabase.co` en `vercel.json` (aparece en `connect-src` y `media-src`). Si no, la página no podrá conectarse.
- **Si agregás una fuente de datos nueva** (otra API, videos de YouTube, otra CDN), hay que añadirla en la cabecera `Content-Security-Policy` de `vercel.json`. Si no, el navegador la bloquea. Ese bloqueo es precisamente la protección.
- **Systeme.io:** si mantenés las dos versiones, las dos usan la misma base de datos. Cuando Vercel funcione bien, conviene retirar el bloque de Systeme.io para tener una sola puerta de entrada.

## Probar en tu computadora (opcional)

```bash
node scripts/build.mjs
npx serve public
```

Este modo no aplica las cabeceras de `vercel.json`. Para probarlas, usá `npx vercel dev`.
