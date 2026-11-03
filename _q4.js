const fs = require("fs");
try {
  const j = JSON.parse(fs.readFileSync("/data/watchtower_state.json", "utf8"));
  const out = {};
  for (const [section, data] of Object.entries(j)) {
    if (Array.isArray(data)) {
      const hits = data.filter(x => String(x).includes("72d248d8"));
      if (hits.length) out[section] = hits;
    } else if (data && typeof data === "object") {
      const hits = Object.keys(data).filter(x => x.includes("72d248d8"));
      if (hits.length) { out[section] = {}; for (const h of hits) out[section][h] = data[h]; }
    }
  }
  console.log(JSON.stringify(out, null, 1).slice(0, 3000));
} catch (e) { console.log("ERR", e.message); }