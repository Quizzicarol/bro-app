import json, websocket, time

RELAYS = ["wss://apexcord.duckdns.org", "wss://relay.primal.net"]
OID = "72d248d8-cd8e-4f48-9b67-4c9ea84c3113"

def fetch(relay, filt, timeout=12):
    try:
        ws = websocket.create_connection(relay, timeout=timeout)
        ws.send(json.dumps(["REQ", "q", filt]))
        out = []
        t0 = time.time()
        while time.time() - t0 < timeout:
            try: msg = json.loads(ws.recv())
            except Exception: break
            if msg[0] == "EVENT": out.append(msg[2])
            elif msg[0] == "EOSE": break
        ws.close()
        return out
    except Exception as e:
        print(relay, "ERR", e)
        return []

def ts(t): return time.strftime("%d/%m %H:%M:%S UTC", time.gmtime(t))

for r in RELAYS:
    print("===", r.split("//")[1])
    # kind 1 com tag t bro-disputa
    for ev in fetch(r, {"kinds": [1], "#t": ["bro-disputa"], "since": 1793200000, "limit": 100}):
        content = ev.get("content", "")
        tags = ev.get("tags", [])
        oid_tag = next((t[1] for t in tags if t[0] == "e" or t[0] == "d"), "")
        if OID in content or OID in str(tags) or oid_tag.startswith("72d248d8"):
            print("  KIND1 disputa pub", ev["pubkey"][:8], ts(ev["created_at"]), content[:80])
    # qualquer kind do provider e1e326ba entre 31/10 e 03/11
    for ev in fetch(r, {"kinds": [30080, 30081], "authors": ["e1e326ba"], "since": 1793400000, "limit": 100}):
        pass  # authors com since ja mostrou problema antes; ignorar