import json, websocket, time

RELAYS = ["wss://apexcord.duckdns.org", "wss://relay.primal.net"]
PREFIX = "72d248d8"

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

full_id = None
order_ev = None
for r in RELAYS:
    evs = fetch(r, {"kinds": [30078], "#t": ["bro-order"], "since": 1793000000, "limit": 400})
    for ev in evs:
        d = next((t[1] for t in ev.get("tags", []) if t[0] == "d"), "")
        if d.startswith(PREFIX):
            full_id = d; order_ev = ev
    if full_id: break

if not full_id:
    print("ordem NAO encontrada por varredura recente")
    raise SystemExit

c = json.loads(order_ev["content"])
print("ORDEM:", full_id)
print("  createdAt content:", c.get("createdAt"), "| status:", c.get("status"), "| amount:", c.get("amount"))
print("  evento created_at (ultima repub):", ts(order_ev["created_at"]))
print("  userPubkey:", str(c.get("userPubkey"))[:8], "| providerId:", str(c.get("providerId"))[:8])

for r in RELAYS:
    print("=== relay", r.split("//")[1])
    # aceites
    for ev in fetch(r, {"kinds": [30079], "#d": [full_id + "_accept"], "limit": 20}):
        try: cc = json.loads(ev["content"])
        except Exception: cc = {}
        print("  ACCEPT pub", ev["pubkey"][:8], "ev:", ts(ev["created_at"]), "acceptedAt:", cc.get("acceptedAt"))
    # updates 30080 (billcode, disputa via status update, etc)
    for ev in fetch(r, {"kinds": [30080], "limit": 500}):
        try: cc = json.loads(ev["content"])
        except Exception: continue
        if cc.get("orderId") != full_id: continue
        t = cc.get("type")
        info = ""
        if t == "bro_billcode_encrypted": info = "billCode cifrado presente"
        if "dispute" in str(t) or cc.get("status") == "disputed": info = "DISPUTA openedBy=%s reason=%s" % (cc.get("openedBy"), str(cc.get("reason"))[:40])
        print("  30080", t, "pub", ev["pubkey"][:8], ts(ev["created_at"]), info)
    # kind 1 com tag da ordem (notificacao de disputa antiga)
    for ev in fetch(r, {"kinds": [1], "#e": [], "limit": 1}):
        pass