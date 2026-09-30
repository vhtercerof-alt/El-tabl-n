// Corrector ortográfico de español que corre en el navegador (sin internet
// ni claves). Usa nspell con el diccionario libre de LibreOffice (dictionary-es).
import nspell from "nspell";

let spell = null;
let cargando = null;

// Palabras de Nicaragua y del habla cotidiana que el diccionario no trae.
const PROPIAS = ("vos sos chavalo chavala chavalos chavalas chele chela cheles chelas chunche chunches maje majes " +
  "tuani pinol pinolillo nica nicas cipote cipota cipotes chigüín chigüines guaro gallopinto vigorón quesillo " +
  "nacatamal nacatamales ideay idiay dale bróder chiva chivas pinolero pinolera pinoleros pinoleras " +
  "whatsapp internet online email wifi").split(" ");

function cargar() {
  if (!cargando) {
    cargando = Promise.all([
      fetch("/motor/es.aff").then((r) => { if (!r.ok) throw new Error("aff"); return r.text(); }),
      fetch("/motor/es.dic").then((r) => { if (!r.ok) throw new Error("dic"); return r.text(); }),
    ]).then(([aff, dic]) => {
      spell = nspell(aff, dic);
      PROPIAS.forEach((p) => spell.add(p));
    });
  }
  return cargando;
}

const TILDE = { a: "á", e: "é", i: "í", o: "ó", u: "ú" };

// Variantes de la palabra con una tilde agregada o cambiada de lugar.
function variantesTilde(w) {
  const base = w.normalize("NFD").replace(/[́]/g, "").normalize("NFC");
  const salida = [];
  for (let i = 0; i < base.length; i++) {
    const c = base[i].toLowerCase();
    if (TILDE[c]) {
      const t = base[i] === c ? TILDE[c] : TILDE[c].toUpperCase();
      const v = base.slice(0, i) + t + base.slice(i + 1);
      if (v !== w) salida.push(v);
    }
  }
  if (base !== w) salida.unshift(base);
  return salida;
}

// Formas del voseo (vos tenés, vos sabés, vení, tomá): se aceptan si el
// infinitivo existe.
function esVoseo(w) {
  const m = w.toLowerCase().match(/^(.+?)(ás|és|ís|á|é|í)$/);
  if (!m) return false;
  const raiz = m[1];
  const fin = m[2];
  const inf = { "ás": ["ar"], "és": ["er"], "ís": ["ir"], "á": ["ar"], "é": ["er"], "í": ["ir"] }[fin];
  return inf.some((x) => spell.correct(raiz + x));
}

function revisar(w) {
  if (spell.correct(w)) return { w, ok: true };
  if (esVoseo(w)) return { w, ok: true, voseo: true };
  const acento = variantesTilde(w).find((v) => spell.correct(v)) || null;
  let sug = [];
  if (!acento) {
    try { sug = spell.suggest(w).slice(0, 4); } catch (e) { sug = []; }
  }
  return { w, ok: false, acento, sug };
}

self.onmessage = async (e) => {
  const { id, palabras } = e.data || {};
  try {
    await cargar();
    const lista = Array.isArray(palabras) ? palabras.slice(0, 3000) : [];
    self.postMessage({ id, ok: true, resultados: lista.map((w) => revisar(String(w).slice(0, 60))) });
  } catch (err) {
    cargando = null;
    self.postMessage({ id, ok: false, error: String(err && err.message || err) });
  }
};
