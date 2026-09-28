# Propuesta: El Tablón para varios cursos

**Estado:** propuesta para decidir. **No se ha implementado nada** de lo que describe este documento.

## 1. Conclusión

Hay tres formas de hacerlo. Recomiendo la **Opción B, "un tablón con varios cursos"**, construida por etapas. Aprovecha lo que ya existe: el mismo **código de invitación** decidiría en qué curso entra cada estudiante. La excepción: si los cursos son de **instituciones distintas** que no deben compartir nada, conviene la **Opción C**.

Antes de construir necesito tus respuestas a las preguntas de la sección 5, porque cambian el diseño.

---

## 2. Situación actual

- Todo El Tablón funciona como **un solo grupo**: todas las tareas, noticias, encuestas, rankings y juegos son visibles para todos los usuarios.
- Hay tres roles globales: `owner`, `admin` y `student`.
- La base tiene unas 30 tablas. Estas son las que la página usa hoy:

| Grupo | Tablas |
|-------|--------|
| Del curso | `tasks`, `task_reactions`, `tb_entregas`, `noticias`, `prensa`, `prensa_reacciones`, `encuestas`, `encuesta_votos`, `memes`, `ranking_snapshots`, `tb_ideas`, `tb_achievements`, `tb_achievement_awards` |
| Personales | `profiles` (Belis, nivel, racha, cosméticos, arcade), `gifts`, `cosmetic_log`, `carreras` |
| Juegos entre dos o más | `ttt_matches`, `pinturillo_partidas`, `bn_partidas`, `stop_salas`, `stop_jugadores` |
| Configuración | `roles`, `member_roles`, `imagenes`, `ruleta_perfiles`, `level_rewards`, `tb_showcase_settings`, `tb_invitaciones`, `tb_ajustes` |

---

## 3. Opciones

### Opción A · Una copia completa por curso
Cada curso tiene su propio proyecto de Supabase y su propia página en Vercel. Es como tener varios tablones independientes.

| A favor | En contra |
|---------|-----------|
| Aislamiento total: un curso nunca ve datos de otro | Cada mejora hay que publicarla en cada copia |
| No hay que cambiar el código | Hay que ejecutar cada archivo SQL en cada proyecto |
| Rápida de montar | Un estudiante en dos cursos necesita dos cuentas |
| | El plan gratuito de Supabase limita cuántos proyectos puedes tener (verifica el límite vigente) |

**Esfuerzo:** bajo al inicio y creciente con cada curso. **Cuándo conviene:** solo para dos cursos sin relación entre sí.

### Opción B · Un tablón con varios cursos (recomendada)
Una sola página y una sola base de datos. Cada tarea, noticia, encuesta o entrega pertenece a un curso, y cada usuario ve solo los cursos en los que está inscrito.

**Cómo funcionaría para el estudiante:**
1. Se registra con el código de invitación de su curso, por ejemplo `GRUPOA26`. Queda inscrito en ese curso automáticamente.
2. Si luego recibe el código de otro curso, lo ingresa en su perfil y queda inscrito en ambos.
3. Arriba de la pantalla aparece un **selector de curso**. Las tareas, noticias, encuestas y el ranking cambian según el curso elegido.

**Cómo funcionaría para ti:**
- **Owner:** crea cursos, ve todos y nombra **profesores** o **ayudantes** por curso.
- **Profesor de un curso:** publica tareas y califica entregas **solo de su curso**. Es un rol nuevo por curso, además del admin global de hoy.
- Las entregas pendientes y los avisos se filtran por curso.

**Cambios técnicos:**
- Tablas nuevas: `cursos` (nombre, color, año, activo) y `curso_miembros` (usuario, curso, rol en el curso: estudiante, profesor o ayudante).
- A las tablas del grupo "Del curso" se les agrega la columna `curso_id`. Todo lo que ya existe pasa a un primer curso, por ejemplo "Grupo original", así **no se pierde nada**.
- Las reglas de seguridad pasan de "¿es staff?" a "¿es miembro, o profesor, de *este* curso?". Esta es la parte más delicada y debe probarse igual que se probaron las entregas.
- Los códigos de invitación tienen un curso asociado.
- Avisos: "nueva tarea" llega solo a los miembros de ese curso.

| A favor | En contra |
|---------|-----------|
| Una sola cuenta por estudiante, aunque esté en varios cursos | Es el cambio más grande: toca casi todas las secciones |
| Una sola página que mantener y publicar | Hay que migrar los datos con cuidado, con respaldo previo |
| Permite sumar otros profesores sin darles poder sobre todo el tablón | Requiere decidir qué se comparte entre cursos (sección 5) |
| Reutiliza los códigos de invitación y las entregas | |

**Esfuerzo:** alto, dividido en etapas que se pueden publicar por separado:

| Etapa | Contenido | Resultado |
|-------|-----------|-----------|
| 1 | Cursos, miembros, selector de curso, códigos por curso, **tareas y entregas por curso**, ranking de cumplidas por curso | Ya se puede dar clase a varios grupos |
| 2 | Noticias, encuestas, memes, buzón de ideas y vitrina por curso; profesor por curso | Cada curso tiene su propio "diario" |
| 3 | Juegos (retos entre compañeros del mismo curso) y reglas de la economía según lo que decidas | Experiencia completa separada |

### Opción C · Mismo código, bases separadas
Un solo repositorio de código. Cada curso o institución tiene su propio proyecto de Supabase y su propio proyecto de Vercel, conectados al mismo repositorio. Cada despliegue lee a qué base conectarse desde sus propias variables de Vercel.

| A favor | En contra |
|---------|-----------|
| Aislamiento total de datos, útil entre colegios o universidades distintas | Hay que ejecutar cada SQL en cada proyecto de Supabase |
| Una mejora se publica sola en todas las copias al subirla a GitHub | Cuentas separadas por institución |
| Cambio de código pequeño: que la dirección de Supabase no esté fija en `index.html` | Límite de proyectos del plan gratuito de Supabase |

**Esfuerzo:** bajo a medio. **Cuándo conviene:** instituciones distintas, o cuando cada una debe ser dueña de sus datos.

---

## 4. Comparación rápida

| Criterio | A · Copias | **B · Varios cursos** | C · Mismo código, bases separadas |
|----------|-----------|-----------------------|-----------------------------------|
| Una cuenta para varios cursos | ✘ | ✔ | ✘ |
| Mantenimiento | Alto | **Bajo** | Medio |
| Aislamiento de datos | Total | Por reglas de la base | Total |
| Otros profesores con permisos limitados | ✘ | ✔ | Solo dentro de cada copia |
| Esfuerzo inicial | Bajo | Alto (por etapas) | Bajo-medio |
| Costo en planes gratuitos | Un proyecto por curso | **Un proyecto** | Un proyecto por institución |

Las opciones B y C se pueden combinar: la B dentro de cada institución y la C entre instituciones.

---

## 5. Preguntas que necesito que respondas

1. **¿Los cursos son de la misma institución o de instituciones distintas?** Si son distintas, conviene C, o C + B.
2. **¿Un mismo estudiante puede estar en más de un curso?**
3. **¿Habrá otros profesores?** Si es así, ¿deben poder publicar tareas y calificar solo en su curso?
4. **Economía y cosméticos:** las Belis, el nivel, la racha, las cartas y los cosméticos, ¿son **del estudiante** (compartidos entre sus cursos) o **por curso**? Recomiendo que sean del estudiante, porque es más simple y no rompe lo que ya tienen.
5. **Ranking:** ¿uno por curso, uno general o ambos? Recomiendo uno por curso, y el general solo visible para ti.
6. **Noticias del Tablón Diario:** ¿cada curso tiene las suyas, o algunas noticias son para todos? Se puede hacer con una opción "publicar en todos los cursos".
7. **¿Cuántos cursos y estudiantes esperas en total?** Sirve para estimar el uso de los planes gratuitos.

---

## 6. Riesgos a considerar

- **Riesgo principal: que un curso vea datos de otro** por una regla mal escrita. Se mitiga con pruebas automáticas de "estudiante del curso A intenta leer el curso B", como las que ya se hicieron para las entregas.
- **Migración:** mover los datos actuales al "Grupo original" requiere un **respaldo previo** de Supabase y hacerlo en un horario sin estudiantes conectados.
- **Versión de Systeme.io:** conviene retirarla antes de la migración, para no tener dos páginas con reglas distintas.
- **Pendiente anterior:** la revisión de reglas de Supabase (Parte A de `supabase/auditoria-seguridad.sql`) debe hacerse **antes** de la Opción B, porque las reglas nuevas se construyen sobre las actuales.

## 7. Siguiente paso propuesto

1. Respondes las preguntas de la sección 5.
2. Ejecutas la Parte A del archivo de auditoría y me pegas los resultados.
3. Diseño la **Etapa 1** con su SQL, la pruebo en una base simulada igual que las entregas y te la entrego para revisarla antes de publicarla.
