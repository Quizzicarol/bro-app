import json, ssl, sys, datetime
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
import websocket

RELAYS = ["wss://apexcord.duckdns.org", "wss://relay.primal.net"]
PREFIX = "c95923aa"
SINCE = int(datetime.datetime(2026,10,16,0,0,0).timestamp())

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

seen = set()
for relay in RELAYS:
    evs = query(relay, [{"kinds":[30078,30079,30080],"#t":["bro-order"],"since":SINCE}])
    for e in evs:
        d = next((t[1] for t in e.get("tags",[]) if t[0]=="d" and len(t)>1), "")
        if d.startswith(PREFIX) and e["id"] not in seen:
            seen.add(e["id"])
            ts = datetime.datetime.fromtimestamp(e["created_at"], datetime.timezone(datetime.timedelta(hours=-3))).strftime("%d/%m %H:%M:%S")
            print(f"--- kind={e['kind']} {ts} pk={e['pubkey'][:8]} ---")
            try:
                print(json.dumps(json.loads(e["content"]), ensure_ascii=False, indent=1)[:800])
            except Exception:
                print(e["content"][:300])