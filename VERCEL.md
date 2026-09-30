# Publicar y configurar El Tablón en Vercel

## Estado actual (28/09/2026)

| Paso | Estado |
|------|--------|
| Proyecto `el-tabl-n-5nqf` en Vercel, conectado a GitHub y publicado en **https://el-tablon1.vercel.app** | ✅ Hecho |
| Rama que se publica en producción: `claude/lucid-curie-14ahbh` (la rama principal del repositorio) | ✅ Hecho |
| Variables `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` (secreta) y `VAPID_SUBJECT` | ✅ Cargadas |
| Clave secreta de Supabase | ⚠️ Está cargada como `PRIVATE_KEY`. La app ahora la reconoce con ese nombre si de verdad es la clave **secret** de Supabase. Lo ideal es renombrarla a `SUPABASE_SERVICE_ROLE_KEY` (paso C.1) |
| Ejecutar en Supabase `ACTIVAR-1-entregas.sql` y `ACTIVAR-3-avisos.sql` | Parte 1 hecha; confirma la 3 (parte B) |
| Borrar de la base de datos los restos del código de invitación: ejecutar `DESACTIVAR-invitaciones.sql` (la página ya no tiene nada de invitaciones) | ⏳ **Falta** (parte B) |
| Economía (ruletas, tienda, regalos, niveles, racha, premio diario): ejecutar `TABLON-economia-segura.sql` y luego abrir la app con la cuenta owner | ⏳ **Falta** (parte B) |
| Activar Analytics | ⏳ **Falta** (paso C.2) |
| Borrar el proyecto duplicado vacío `el-tablon` (Settings → Delete Project) | ⏳ **Falta** |
| Herramientas con IA (Profesor de lengua y Voleibol): cargar `GEMINI_API_KEY` y ejecutar `ACTIVAR-4-permisos-roles.sql` (paso C.4) | ⏳ **Falta** |


Esta guía tiene tres partes. Hazlas en orden y una sola vez:

- **A. Publicar la página** (unos 10 minutos).
- **B. Activar entregas y avisos en Supabase** (unos 5 minutos).
- **C. Conectar los avisos y las estadísticas en Vercel** (unos 10 minutos).

---

## Cómo está organizado el repositorio

| Archivo | Para qué sirve |
|---------|----------------|
| `index.html` | **La app.** Es el único archivo que editas para cambiar la página. |
| `api/notificar.js`, `api/push-clave.js` | Pequeño servidor en Vercel que envía los avisos al celular. |
| `pwa/` | Ícono, manifiesto y *service worker*: permiten instalar la app y recibir avisos. |
| `supabase/*.sql` | Instrucciones para la base de datos. Se ejecutan en Supabase, no en Vercel. |
| `scripts/build.mjs` | Vercel lo ejecuta en cada publicación: arma la carpeta `public/`. |
| `vercel.json` | Configuración de Vercel y cabeceras de seguridad. |

Solo se publica lo que va en `public/` y en `api/`. El informe, los archivos SQL y los scripts **no** quedan visibles en internet.

---

## A. Publicar la página

1. **Crea la rama principal en GitHub.** El trabajo está en la rama `claude/lucid-curie-14ahbh`. En github.com, abre un *Pull Request* de esa rama hacia `main` y haz clic en *Merge*. Vercel publica en producción la rama principal.
2. Entra a <https://vercel.com> e inicia sesión con tu cuenta de GitHub.
3. Haz clic en **Add New… → Project** e importa `vhtercerof-alt/El-tabl-n`. Si no aparece, usa *Adjust GitHub App Permissions* y dale acceso a ese repositorio.
4. En la configuración deja **Framework Preset: Other**. El resto ya viene definido en `vercel.json`.
5. Haz clic en **Deploy**. Te dará una dirección del tipo `https://el-tabl-n.vercel.app`.
6. En **Supabase → Authentication → URL Configuration**, pon esa dirección en **Site URL**.

---

## B. Activar entregas y avisos (Supabase)

Son archivos cortos que están en la carpeta `supabase/`:

| Archivo | Qué hace |
|---------|----------|
| `ACTIVAR-1-entregas.sql` | Activa las entregas de tareas y su calificación |
| `ACTIVAR-3-avisos.sql` | Activa los avisos al celular |
| `DESACTIVAR-invitaciones.sql` | **Quita** los códigos de invitación: vuelve a permitir crear cuentas sin código. Ejecútalo si llegaste a correr el antiguo `ACTIVAR-2-invitaciones.sql` |
| `TABLON-economia-segura.sql` | Activa girar ruletas, la tienda, abrir regalos, las recompensas de nivel, la racha y el premio diario. **Después de ejecutarlo, abre El Tablón una vez con tu cuenta de owner** para que se cargue el catálogo de premios |

Para **cada** archivo:

1. En GitHub, abre el archivo y usa el botón **Copy raw file** (ícono de dos cuadritos, arriba a la derecha del contenido). Así se copia completo.
2. En Supabase: **SQL Editor → New query**, para tener una pestaña **vacía**.
3. Pega con Ctrl+V (Cmd+V en Mac). **No selecciones nada**: si hay texto seleccionado, Supabase ejecuta solo esa parte.
4. Haz clic en **Run**. Debe aparecer una tabla con un mensaje de resultado.

Todos se pueden ejecutar varias veces sin romper nada.

> Iniciar sesión **nunca** necesitó código. Los códigos solo afectaban a la creación de cuentas nuevas.

---

## C. Avisos y estadísticas (Vercel)

### C.1 Variables de entorno (claves)

En Vercel: **tu proyecto → Settings → Environment Variables**. Agrega estas seis. Marca los tres entornos (*Production*, *Preview*, *Development*), salvo `SUPABASE_SERVICE_ROLE_KEY`, que conviene poner **solo en Production**.

| Nombre | Dónde la consigues | ¿Es secreta? |
|--------|-------------------|--------------|
| `SUPABASE_URL` | Es la misma de `index.html`: `https://quppebdummixryqqcady.supabase.co` | No |
| `SUPABASE_ANON_KEY` | Es la misma `SUPABASE_ANON_KEY` que aparece en `index.html` | No |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → **Project Settings → API Keys** → la clave **secret** (o `service_role` en proyectos antiguos). El nombre tiene que ser exactamente este | **Sí, muy secreta** |
| `VAPID_PUBLIC_KEY` | Archivo `CLAVES-AVISOS-PRIVADO.txt` que te entregué | No |
| `VAPID_PRIVATE_KEY` | El mismo archivo | **Sí** |
| `VAPID_SUBJECT` | La dirección de la app (`https://el-tablon1.vercel.app`) o `mailto:` y tu correo | No |

> ⚠️ **La clave secreta de Supabase abre toda la base de datos.** Va únicamente en Vercel. Nunca la pongas en `index.html`, en GitHub, en un chat ni en una captura de pantalla. Si se filtra, en Supabase puedes generar una nueva y desactivar la anterior.

Si pierdes el archivo de claves de avisos, se pueden generar otras con `npx web-push generate-vapid-keys`. Al cambiarlas, cada persona tendrá que volver a activar los avisos.

Después de guardar las variables, ve a **Deployments → último despliegue → ⋯ → Redeploy**. Las variables solo se aplican a los despliegues nuevos.

### C.2 Estadísticas de visitas

En Vercel: **tu proyecto → Analytics → Enable**. No hace falta tocar código: la página ya incluye el script. Las estadísticas no usan cookies ni guardan datos personales. Empiezan a mostrarse unos minutos después de las primeras visitas.

### C.3 Probar los avisos

1. Abre la página publicada en tu celular. En Android, usa Chrome.
2. En **Inicio** aparece la tarjeta **🔔 Activa los avisos**. Tócala y acepta el permiso. Una vez activados, la tarjeta desaparece de Inicio y queda en **Temas**, donde puedes probarlos o desactivarlos.
   - **iPhone/iPad:** primero toca **Compartir → Agregar a pantalla de inicio** y abre El Tablón desde ese ícono. Apple solo permite avisos en apps instaladas así.
3. Desde otra cuenta (o la computadora), publica una tarea de prueba. Te debe llegar el aviso **📌 Nueva tarea**.

Si no llega:

1. En **Temas**, en la tarjeta de avisos, toca **Enviar aviso de prueba**. Si algo está mal, la tarjeta muestra el motivo: a ti, como owner, con el detalle de qué ajuste falta.
2. Revisa que el celular no esté en modo «No molestar» y que Chrome o Safari tengan permitidas las notificaciones en los ajustes del teléfono.
3. Si cambiaste alguna variable en Vercel, haz **Redeploy**.
4. Si sigue sin funcionar, en esa misma tarjeta toca **Desactivar avisos** y luego **Activar avisos** otra vez.

### C.4 Herramientas con IA (Profesor de lengua y Voleibol)

Las dos herramientas de **Actividades** usan **Google Gemini** desde el servidor de Vercel. La clave nunca llega al navegador.

1. Entra a **https://aistudio.google.com** con tu cuenta de Google → **Get API key** → **Create API key**.
2. En Vercel → **Settings → Environment Variables** agrega `GEMINI_API_KEY` con esa clave (marca **Sensitive**, entorno *Production*).
3. En Supabase ejecuta **`supabase/ACTIVAR-4-permisos-roles.sql`** (permiso del voleibol).
4. **Deployments → Redeploy**.

**Quién puede usar cada una:**
- **Profesor de lengua:** todos los usuarios con sesión iniciada.
- **Voleibol:** solo el owner, y quien tenga un rol con el permiso activado: **Roles → elige el rol → pestaña Permisos → 🏐 Voleibol**. El servidor vuelve a comprobarlo en cada uso.

Variables opcionales:

| Variable | Por defecto |
|----------|-------------|
| `GEMINI_MODEL` | `gemini-flash-latest` (alias de Google que apunta siempre al Flash más reciente) |
| `IA_LIMITE_LENGUA` | 15 revisiones por estudiante y día |
| `IA_LIMITE_VOLEIBOL` | 10 análisis por persona con permiso y día |
| `IA_LIMITE_STAFF` | 40 usos por herramienta para owner y admins |

El contador diario se reinicia a medianoche de Nicaragua y usa la tabla de `ACTIVAR-3-avisos.sql`. Si la IA falla, el intento **no** se descuenta.

**Plan gratuito de Gemini:** no cobra, pero tiene límites de solicitudes por minuto y por día **para todo el proyecto** (se comparten entre todos los estudiantes). Si se agotan, la herramienta dice "Se agotó la cuota de la IA por ahora". Consulta tus límites en AI Studio y los precios en https://ai.google.dev/gemini-api/docs/pricing.

> ⚠️ **Privacidad:** en el plan gratuito, Google puede usar los textos enviados para mejorar sus productos. Si activas facturación en Google AI Studio, deja de hacerlo. Avísales a los estudiantes que no pongan datos personales en los textos.

---

## Cómo se usa cada función

### Entregas y cumplidos

- **Estudiante:** en el menú aparece la pestaña **📥 Entregas**, con todas las tareas publicadas, su estado y el botón **📤 Entregar**. La insignia roja indica cuántas tiene por entregar o corregir. Puede escribir su respuesta y/o adjuntar una foto o un PDF (máximo 5 MB). Las fotos se reducen y se les borran datos ocultos como la ubicación GPS. Mientras no esté aprobada, puede editar su entrega.
- **Tú (owner o admin):** la misma pestaña **📥 Entregas** muestra la bandeja de revisión, con el número de entregas pendientes. En cada entrega puedes:
  - **✅ Aprobar y dar cumplido:** suma 1 al contador de tareas cumplidas del estudiante (el del ranking), con nota opcional de 0 a 100 y comentario;
  - **↩️ Devolver para corregir:** el estudiante ve tu comentario y puede volver a entregar.
- Aprobar dos veces la misma entrega no suma dos cumplidos. Si devuelves una entrega que ya estaba aprobada, se resta el cumplido.
- Los archivos son **privados**: solo los ven el estudiante que los subió y el owner o los admins, mediante enlaces temporales de 10 minutos.
- El botón manual **Cumplimientos** del panel del owner sigue funcionando como antes.

### Avisos que se envían

| Qué pasa | Quién recibe el aviso |
|----------|-----------------------|
| Publicas una tarea (nueva, o al marcar una como publicada) | Todos, incluido tú, una sola vez por tarea. Al publicar, un mensaje en pantalla te dice a cuántos dispositivos llegó |
| Un estudiante entrega o reenvía | Owner y admins |
| Calificas una entrega | Solo ese estudiante |
| Tú envías un **aviso personalizado** desde *Panel del owner → Enviar un aviso personalizado* | Quien elijas: todos, solo estudiantes, solo owner y admins, o una persona |
| Cada día a las 8:00 (hora de Nicaragua), si quedan entregas sin revisar | Owner y admins: «Tienes N entregas esperando tu calificación» |

El recordatorio diario lo ejecuta Vercel automáticamente (sección *Cron Jobs* del proyecto) y está protegido con la variable secreta `CRON_SECRET`, que ya quedó cargada. Para cambiar la hora, edita `"schedule"` en `vercel.json`: la hora va en UTC, y 14:00 UTC son las 8:00 en Nicaragua.

**Importante:** si en el mismo celular o navegador entras con otra cuenta (por ejemplo, una de estudiante para probar), al cerrar sesión ese dispositivo deja de recibir tus avisos. Vuelve a activarlos cuando entres con tu cuenta.

El texto de cada aviso lo arma siempre el servidor. Nadie puede usar el sistema para mandar mensajes inventados. Al cerrar sesión, ese dispositivo deja de recibir avisos.

---

## Mantenimiento

- **Actualizar la app:** edita `index.html`, haz commit y push a `main`. Vercel vuelve a publicar solo.
- **Volver atrás:** Vercel → Deployments → elige una versión anterior → ⋯ → **Promote to Production**.
- **Espacio de almacenamiento:** las fotos y PDF de las entregas ocupan espacio en Supabase. Revisa de vez en cuando **Supabase → Storage → entregas** y el uso del plan.
- **Si cambias de proyecto Supabase:** cambia la dirección en `index.html`, en `vercel.json` (`connect-src` y `media-src`) y en la variable `SUPABASE_URL`.
- **Si agregas una fuente externa nueva** (otra API, videos), añádela a `Content-Security-Policy` en `vercel.json`; si no, el navegador la bloquea.
- **Systeme.io:** la versión pegada ahí sigue funcionando para las entregas, pero **no** puede enviar avisos ni instalarse como app. Conviene dejar solo la de Vercel.

## Probar en tu computadora (opcional)

```bash
npm install
node scripts/build.mjs
npx vercel dev
```
