import json, ssl, sys, datetime
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import websocket

RELAYS = ["wss://apexcord.duckdns.org", "wss://relay.primal.net"]
PREFIX = "2706f28d"
SINCE = int(datetime.datetime(2026,10,17,0,0,0).timestamp())

def query(relay, filters, timeout=12):
    out = []
    try:
        ws = websocket.create_connection(relay, timeout=timeout, sslopt={"cert_reqs": ssl.CERT_NONE})
        ws.send(json.dumps(["REQ","s1",*filters]))
        ws.settimeout(timeout)
        while True:
            try: msg = json.loads(ws.recv())
            except Exception: break
            if msg[0]=="EOSE": break
            if msg[0]=="EVENT": out.append(msg[2])
        ws.close()
    except Exception as e:
        print(f"  [{relay}] ERRO: {e}")
    return out

for relay in RELAYS:
    evs = query(relay, [{"kinds":[1],"#t":["bro-mediacao","bro-disputa-chat"],"since":SINCE}])
    hits = []
    for e in evs:
        r = next((t[1] for t in e.get("tags",[]) if t[0]=="r" and len(t)>1), "")
        if r.startswith(PREFIX):
            hits.append(e)
    print(f"=== {relay}: {len(hits)} msgs de mediacao/chat da disputa {PREFIX} ===")
    hits.sort(key=lambda e: e["created_at"])
    for e in hits:
        ts = datetime.datetime.fromtimestamp(e["created_at"], datetime.timezone(datetime.timedelta(hours=-3))).strftime("%d/%m %H:%M:%S")
        try:
            c = json.loads(e["content"])
            tipo = c.get("type","?")
            role = c.get("senderRole", c.get("target",""))
            txt = (c.get("message") or "")[:60]
        except Exception:
            tipo, role, txt = "?", "?", ""
        print(f"  {ts} pk={e['pubkey'][:8]} type={tipo} role/target={role} msg={txt!r}")