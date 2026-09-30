# Motor integrado (sin API)

Archivos que usa el **Profesor de lengua** para revisar la ortografía dentro del navegador, sin internet ni claves:

| Archivo | Qué es |
|---------|--------|
| `es.aff`, `es.dic` | Diccionario de español de LibreOffice, paquete `dictionary-es` 4.0.0. Licencia en `LICENCIA-diccionario.txt` (GPL-3.0, LGPL-3.0 o MPL-1.1) |
| `ortografia.js` | Corrector que corre en un *Web Worker*: `ortografia.fuente.js` empaquetado con `nspell` 2.1.5 (MIT) |
| `ortografia.fuente.js` | Código fuente del corrector |

Para regenerar `ortografia.js` después de cambiar la fuente:

```bash
npm i --no-save nspell@2.1.5 esbuild
npx esbuild motor/ortografia.fuente.js --bundle --minify --format=iife --platform=browser --target=es2019 --legal-comments=inline --outfile=motor/ortografia.js
```

`scripts/build.mjs` copia estos archivos a `public/motor/`.
