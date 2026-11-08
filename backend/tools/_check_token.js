// checa token push de uma pubkey (roda na máquina Fly). NÃO commitar.
const k = process.argv[2];
const t = require('/data/push_tokens.json');
const e = t[k] || (t.tokens && t.tokens[k]);
if (!e) {
  // talvez o formato seja lista
  const all = Array.isArray(t) ? t : Object.entries(t.tokens || t);
  const hit = all.find(x => JSON.stringify(x).includes(k));
  console.log('NAO ACHADO por chave. busca livre:', hit ? JSON.stringify(hit).substring(0, 400) : 'NADA');
} else {
  console.log(JSON.stringify(e).substring(0, 500));
}
