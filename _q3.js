const fs = require("fs");
try {
  const j = JSON.parse(fs.readFileSync("/data/billcode_wakeups.json", "utf8"));
  const k = Object.keys(j).filter(x => x.startsWith("72d248d8"));
  console.log("CHAVES 72d248d8:", JSON.stringify(k));
  for (const key of k) console.log(key, "=>", JSON.stringify(j[key]));
  console.log("total entries:", Object.keys(j).length);
} catch (e) { console.log("ERR", e.message); }