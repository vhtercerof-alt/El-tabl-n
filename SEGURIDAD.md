# Informe de seguridad · El Tablón

**Archivo revisado:** `tablon_ruletas_editor_de_fotos (5).html` (en este repositorio: `index.html`)
**Tipo de app:** página que se pega en un bloque de código de Systeme.io y guarda todo en Supabase (usuarios, perfiles, tareas, noticias, memes, juegos, economía de "Belis").
**Fecha de revisión:** 27/09/2026

---

## 1. Resumen en pocas líneas

- **El problema más grave estaba en la página y ya está corregido.** La función que "limpiaba" los textos de los usuarios antes de mostrarlos no neutralizaba las comillas. Un estudiante podía poner código escondido en un meme, un nombre o una dirección de imagen, y ese código se ejecutaba en la computadora de **cualquier persona que lo viera, incluido el owner**. Así podía robar su sesión y actuar como owner: cambiar roles, borrar usuarios o asignar contraseñas.
- **La otra mitad de la seguridad no está en este archivo, sino en Supabase.** La página se comunica directamente con la base de datos. Todo lo que la página "no deja hacer" (dar Belis, cambiarse el rol, aprobar memes, editar noticias) lo puede intentar cualquier usuario desde la consola del navegador. Solo lo impiden las **reglas de la base de datos (RLS)**, y esas reglas no estaban disponibles para esta revisión. Por eso dejé un archivo de verificación (`supabase/auditoria-seguridad.sql`) para comprobarlas.
- La clave de Supabase que aparece en el código (`SUPABASE_ANON_KEY`) **no es una filtración**: es la clave pública, está pensada para ir en la página y no da acceso de administrador.

---

## 2. Problemas encontrados y por qué eran un riesgo

| # | Problema | Gravedad | Estado |
|---|----------|----------|--------|
| 1 | Los textos de usuarios podían "romper" el HTML e inyectar código (comillas sin neutralizar) | **Crítica** | ✅ Corregido |
| 2 | Direcciones de imágenes guardadas en la base se usaban sin validar | **Alta** | ✅ Corregido |
| 3 | La librería de Supabase se descargaba "siempre la última 2.x" sin verificar que no hubiera sido alterada | **Alta** | ✅ Corregido |
| 4 | Varias acciones sensibles dependen solo de reglas de la base de datos que no pude ver | **Alta (por verificar)** | ⚠️ Pendiente: verificación en Supabase |
| 5 | El registro aceptaba contraseñas muy fáciles de adivinar | Media | ✅ Corregido |
| 6 | La contraseña que el owner asigna a un usuario se escribía a la vista | Media | ✅ Corregido |
| 7 | Colores de roles insertados en estilos sin validar | Baja | ✅ Corregido |
| 8 | Identificadores de la base puestos en botones sin escapar | Baja | ✅ Corregido (preventivo) |
| 9 | Registro abierto: cualquiera que encuentre la página puede crear una cuenta | Media | ✅ Resuelto con códigos de invitación (sección 6 ter) |
| 10 | Imágenes cargadas desde sitios de terceros (Tenor, Pinterest, wsrv.nl…) | Baja (privacidad) | 💬 Recomendación |
| 11 | Dominio de correo interno `eltablon-app.com` | Media (por verificar) | 💬 Recomendación |

### Detalle

**1 · Inyección de código a través de textos y comillas (crítico).**
La app arma casi todas sus pantallas juntando texto e información de la base de datos. Para que un texto no se interprete como código, usaba una función llamada `escapeHtml`. Esa función convertía `<` y `>`, pero **no las comillas**. Muchos datos se colocan *dentro de comillas* (la dirección de una imagen, un título, un color). Por ejemplo, un meme guardado con una "imagen" que tuviera comillas y un fragmento de código podía cerrar esas comillas y ejecutar instrucciones en el navegador de cada persona que abriera la galería.
*Por qué importa:* la sesión de Supabase se guarda en el navegador. Quien ejecuta código ahí puede tomar esa sesión y hacerse pasar por la víctima. Si la víctima es el owner, el atacante obtiene el control total del tablón.

**2 · Direcciones de imágenes sin validar (alto).**
Fotos de perfil, escudos, premios, noticias, memes y fondos se mostraban tal como venían de la base de datos. Una dirección manipulada podía salirse del espacio reservado para la imagen y alterar la página, o cargar contenido desde sitios no previstos.

**3 · Librería externa sin versión fija ni verificación (alto).**
La primera línea cargaba `supabase-js@2` desde jsDelivr. Eso significa "dame la última versión 2.x que exista". Si esa librería o el CDN fueran comprometidos, o si saliera una versión con errores, la página la cargaría sin avisar. Esa librería maneja **usuarios y contraseñas**.

**4 · Reglas de la base de datos (alto, por verificar).**
Algunas acciones que la página considera "solo del owner" o "solo del staff" se hacen escribiendo directamente en tablas. Entre ellas: publicar y editar noticias, enviar regalos, crear roles, aprobar memes, editar imágenes y cambiar el catálogo de la ruleta. Hay además acciones de cualquier usuario que requieren permisos amplios:
- El contador de vistas de noticias se actualiza con un `UPDATE` sobre la tabla `prensa` hecho **por cualquier usuario**. Si la regla permite eso, cualquier estudiante podría también **reescribir las noticias**.
- Un estudiante envía su meme con `aprobado: false`, pero nada en la página impide que lo envíe con `true` desde la consola. Solo lo impide la regla de la base.
- Los perfiles se actualizan directamente (tema, bio, objeto equipado, puntajes del arcade). Si la regla permite actualizar **cualquier columna** del propio perfil, un estudiante podría cambiarse el `role` a `owner`, sumarse Belis o desbloquear premios.
- Los puntajes del arcade y las partidas de "X y O" los escribe el propio navegador. Se pueden falsear. Afecta a la limpieza de los rankings, no a la seguridad de las cuentas.

La página hace referencia a archivos SQL propios (`TABLON-economia-segura.sql`, `ACTIVAR-buzon-y-vitrina.sql`). Eso indica que parte de esto ya se protegió en el servidor. **Hay que confirmarlo; no se puede suponer.**

**5 · Contraseñas débiles.** El medidor de fortaleza avisaba, pero dejaba registrarse con `12345678` o con el propio usuario como contraseña.

**6 · Contraseña visible al asignarla.** El campo donde el owner escribe la contraseña nueva de un estudiante era de texto normal. Cualquiera que mirara la pantalla (o una grabación de pantalla o clase proyectada) la veía.

**9 · Registro abierto.** Cualquier persona que llegue a la página puede crear una cuenta, sin invitación, y entrar al tablón del grupo. Lo que puede ver y hacer después depende de las reglas del punto 4.

**10 · Imágenes de terceros.** Muchas fotos de la ruleta se cargan desde Tenor, Pinterest, Twitter y otros sitios. Las plantillas de memes pasan por `wsrv.nl`. Cada vez que un estudiante ve esas imágenes, su navegador contacta a esos servicios, que registran su dirección IP. Además, si una imagen se borra o se reemplaza allá, cambia en el tablón.

**11 · Dominio de correo interno.** Las cuentas usan correos inventados del tipo `usuario@eltablon-app.com`. Si ese dominio no es tuyo, quien lo registre podría, en ciertas configuraciones, recibir correos de "recuperar contraseña" de tus usuarios.

---

## 3. Cambios aplicados en el código

Todos los cambios están en `index.html`. El primer commit guarda la versión original, así que es fácil comparar o volver atrás.

1. **Función `escapeHtml` reescrita.** Ahora neutraliza también `"` y `'`. Como la usa toda la app, este único cambio cierra la inyección en todos los lugares donde se muestran nombres, títulos, bios, respuestas, encuestas, etc.
2. **Nueva función `safeUrl`.** Toda imagen que viene de la base pasa por un filtro:
   - solo acepta direcciones `https://` o `http://`, imágenes incrustadas (`data:image/...;base64`) y archivos locales temporales (`blob:`);
   - rechaza `javascript:`, direcciones con usuario y contraseña, y caracteres de control;
   - codifica los caracteres que podrían "escaparse" del espacio de la imagen.

   Se aplicó a fotos de perfil, podio, noticias, vista previa de noticias, escudos, avatares del juego, premios, fondos, plantillas y galería de memes, y a la tabla `imagenes` (que ahora descarta al cargar cualquier dirección inválida).
3. **Librería de Supabase fijada a la versión 2.117.2**, con **huella de integridad (SRI)**. Si alguien altera el archivo en el CDN, el navegador se niega a ejecutarlo. Se comprobó que la huella coincide con el paquete oficial publicado en npm.
4. **Nueva función `safeCssColor`.** El color de cada rol solo se acepta si es un color válido (`#hex`, `rgb()`, `hsl()` o un nombre simple).
5. **Identificadores en botones escapados** (34 lugares: regalos, tareas, perfiles, roles, noticias, encuestas, partidas). Es una medida preventiva por si algún identificador llegara a ser texto controlado por un usuario.
6. **Registro con contraseña mínima razonable.** Se rechazan contraseñas que contienen el usuario o que el propio medidor de la app califica como muy débiles. El usuario se valida también en el código (solo `a-z`, `0-9` y `_`, de 3 a 24 caracteres), no solo en el formulario.
7. **Asignar contraseña (owner).** El campo queda oculto (tipo contraseña) y se exigen al menos 10 caracteres. El aviso final sigue mostrando la contraseña para que el owner pueda pasársela al estudiante.
8. **"Reiniciar mis giros" del owner** ahora usa la función del servidor `owner_reset_spins` (que ya existía y verifica el rol) en lugar de escribir el perfil directamente. Así, en Supabase se puede prohibir a todos los usuarios tocar sus contadores de giro sin romper este botón.
9. **Imágenes de plantillas de memes** se cargan sin enviar de qué página viene el visitante (`referrerpolicy="no-referrer"`).

**Verificación realizada:** se comprobó que el código JavaScript no tiene errores de sintaxis. También se abrió la página en un navegador automático, antes y después de los cambios: carga igual, la librería pasa la verificación de integridad y no aparecen errores. Las funciones nuevas se probaron con ejemplos de ataque (comillas, `javascript:`, `data:text/html`, colores con CSS inyectado) y todas los bloquean. **No se probó el flujo completo contra tu Supabase real** (iniciar sesión, girar la ruleta, etc.), porque este entorno no tiene acceso a él. Conviene hacer una prueba rápida después de publicar.

---

## 4. Decisiones de diseño que **no** apliqué (requieren tu decisión)

Estas cambian cómo funciona la app o dependen de la base de datos, que no pude ver:

| Decisión | Opción recomendada | Costo / efecto |
|----------|-------------------|----------------|
| Restringir qué columnas del perfil puede editar cada usuario | Permitir solo `theme`, `light_mode`, `bio`, `arcade`, `terms_accepted_at` y los objetos equipados; todo lo demás, por funciones del servidor | Hay que probar que la ruleta, la tienda y el canje sigan funcionando |
| Contador de vistas de noticias | Pasarlo a una función del servidor y quitar a los estudiantes el permiso de editar `prensa` | Cambio pequeño en la página + SQL (plantilla B.3) |
| Imágenes de terceros | Subir las fotos de la ruleta y las plantillas de memes a tu propio Storage de Supabase | Trabajo manual de subir imágenes |

---

## 5. Qué hacer ahora en Supabase (en este orden)

1. Abrí el **SQL Editor** y ejecutá la **Parte A** de `supabase/auditoria-seguridad.sql`. Son solo consultas de lectura: no cambian nada.
2. Revisá los resultados:
   - **A.1** debe salir vacío (todas las tablas con RLS activado).
   - **A.2**: ninguna política de `INSERT`, `UPDATE` o `DELETE` debe tener `true` en tablas que solo el staff debería tocar (`prensa`, `noticias`, `gifts`, `roles`, `member_roles`, `imagenes`, `ruleta_perfiles`, `level_rewards`, `tasks`, `encuestas`, `tb_achievements`, `tb_showcase_settings`).
   - **A.3**: `authenticated` **no** debe poder actualizar `role`, `belis`, `level`, las listas de objetos (`cards`, `banners`, `motions`, `avatars`, `borders`) ni los `last_spin*`.
   - **A.4**: cada función `owner_*` debe comprobar que quien la llama es owner. La segunda consulta lista las que no mencionan `auth.uid()`: revisalas primero.
   - **A.5**: en Storage, solo owner y admin deben poder **subir** archivos.
   - **A.6**: el alta de usuarios **no** debe tomar el rol de los datos que envía el navegador.
3. Si algo falla, adaptá las plantillas de la **Parte B**. Probalas primero en una copia del proyecto o en un momento sin estudiantes conectados.

---

## 6. Recomendaciones para mantener la app segura

1. **Regla de oro:** nunca confíes en que la página "no muestra el botón". Toda acción importante (dar Belis, premios, roles, aprobar, borrar) debe estar protegida **en Supabase**, con RLS o con funciones que verifiquen el rol.
2. **Al agregar funciones nuevas que muestren texto de usuarios**, usá siempre `escapeHtml(...)`. Para imágenes, usá `escapeHtml(safeUrl(...))`. O, mejor todavía, asigná el texto con `textContent` en lugar de `innerHTML`.
3. **Nunca pongas en la página la clave `service_role`** de Supabase. Solo la `anon` (la actual).
4. **Actualizar la librería de Supabase:** cuando quieras una versión nueva, cambiá el número de versión **y** la huella `integrity` (se obtiene en jsdelivr.com, en la página del archivo, con "Copy SRI"). Si cambiás solo uno de los dos, la página no cargará. Es a propósito: falla de forma segura.
5. **Dominio de correo:** comprobá que `eltablon-app.com` sea tuyo o registralo. Si no, no configures un servidor de correo (SMTP) propio en Supabase, porque los correos de recuperación irían a ese dominio.
6. **Cuentas owner/admin:** usá contraseñas largas y únicas, y no inicies sesión como owner en computadoras compartidas del aula. Cerrá sesión al terminar.
7. **Copias de seguridad:** activá los respaldos de Supabase (o exportá periódicamente) antes de cambiar reglas.
8. **Revisión periódica:** una vez por trimestre, repetí la Parte A del archivo SQL y revisá en Supabase los *Advisors* (Security Advisor), que avisan de tablas sin RLS y funciones inseguras.
9. **Mensajes de error:** hoy la app muestra al usuario el mensaje técnico de la base (`alert(error.message)`). No es grave, pero revela nombres de tablas. A futuro conviene mostrar un mensaje genérico y dejar el detalle en la consola.
10. **Datos de menores:** si los estudiantes son menores de edad, mantené la regla que ya muestra la app (no pedir teléfono, correo real ni dirección) y evitá guardar fotos reales de ellos en servicios de terceros.

---

## 6 bis. Versión para Vercel (cabeceras de seguridad)

Al publicar en Vercel (ver `VERCEL.md`), `vercel.json` agrega protecciones que Systeme.io no permitía:

- **Content-Security-Policy:** el navegador solo ejecuta código del propio sitio y de la librería fijada en jsDelivr. Solo se conecta a tu proyecto de Supabase. Aunque apareciera un nuevo fallo de inyección, un código inyectado no podría ejecutarse ni enviar datos a otro servidor.
- **X-Frame-Options / frame-ancestors:** otra página no puede mostrar el tablón dentro de un marco para engañar a los usuarios (*clickjacking*).
- **Strict-Transport-Security:** siempre por conexión cifrada (HTTPS).
- **X-Content-Type-Options, Referrer-Policy, Permissions-Policy:** evitan interpretaciones peligrosas de archivos, no revelan de qué página vienen los visitantes y bloquean cámara, micrófono y ubicación.

Se probó en navegador con estas cabeceras: la portada y el ingreso cargan sin errores ni bloqueos. Las pantallas internas (después de iniciar sesión) no se pudieron probar sin acceso a tu Supabase. Si algo no carga, la consola del navegador mostrará "Content Security Policy" con el recurso bloqueado.

## 6 ter. Seguridad de las funciones nuevas (entregas, invitaciones, avisos)

Cómo se diseñaron para que no abran nuevas puertas:

- **Códigos de invitación:** los valida la **base de datos** en el momento de crear la cuenta. Desde el navegador no se pueden saltar. Nadie más que el owner puede ver la lista de códigos. Se generan al azar, con 8 caracteres (más de un billón de combinaciones). Cada código puede tener límite de usos y fecha de vencimiento. El código no queda guardado en el perfil del usuario.
- **Entregas:** los estudiantes **no escriben directamente** en la tabla. Todo pasa por funciones del servidor que comprueban:
  - que la tarea esté publicada;
  - que el archivo esté en la carpeta del propio estudiante;
  - que no se reenvíe más de una vez cada 30 segundos;
  - que una entrega aprobada ya no se pueda cambiar.

  Solo el owner o un admin pueden calificar. El cumplido se suma una sola vez, dentro de la misma operación, para que no se pueda duplicar.
- **Archivos de entregas:** van en un espacio **privado** de Supabase, con un máximo de 5 MB y solo imágenes o PDF. Se muestran mediante enlaces temporales de 10 minutos. A las fotos se les quitan datos ocultos como la ubicación GPS.
- **Avisos:** el servidor de Vercel comprueba la sesión de quien pide el aviso y su rol, y **arma él mismo el texto**. Un estudiante no puede anunciar tareas, avisar sobre entregas ajenas ni mandar mensajes inventados. Cada aviso se envía una sola vez. La clave secreta de Supabase y la clave privada de avisos viven solo en Vercel.
- **Pruebas realizadas:**
  - el SQL se ejecutó dos veces seguidas en una base PostgreSQL que imita a Supabase, con escenarios de ataque (estudiante que intenta aprobarse, usar archivos ajenos, escribir directo en las tablas, registrarse sin código o con un código agotado): todos quedaron bloqueados;
  - la función de avisos pasó 13 pruebas de autorización;
  - los flujos completos de estudiante y owner se probaron en navegador con datos simulados.

  **No se probó contra tu Supabase real.**

## 7. Pendientes de verificar

- Reglas RLS, permisos de columnas y funciones `owner_*` en Supabase (Parte A del SQL).
- Contenido de `TABLON-economia-segura.sql` y `ACTIVAR-buzon-y-vitrina.sql`, que no se revisaron porque no estaban disponibles.
- Que la función `owner_reset_spins` acepte el identificador de un solo usuario (la página ya la llamaba con `target_user`; ahora también la usa para "mis giros").
- Prueba manual tras publicar: iniciar sesión, girar una ruleta, abrir la galería de memes, publicar una noticia con foto y asignar una contraseña de prueba.
