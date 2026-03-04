/**
 * nostrListenerService.js — Monitors Nostr relays for dispute events
 * 
 * Subscribes to kind:1 events with #t=bro-disputa and #t=bro-disputa-evidencia
 * to detect new disputes and evidence in real-time.
 * 
 * v271 Phase 4: AI Dispute Agents
 */

const WebSocket = require('ws');
const EventEmitter = require('events');

const RELAYS = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

// Nostr event kinds we care about
const DISPUTE_FILTERS = [
  {
    kinds: [1],
    '#t': ['bro-disputa'],
    since: Math.floor(Date.now() / 1000) - 86400, // Last 24h on startup
  },
  {
    kinds: [1],
    '#t': ['bro-disputa-evidencia'],
    since: Math.floor(Date.now() / 1000) - 86400,
  },
  {
    kinds: [1],
    '#t': ['bro-resolucao'],
    since: Math.floor(Date.now() / 1000) - 86400,
  },
];

class NostrListenerService extends EventEmitter {
  constructor() {
    super();
    this._connections = new Map(); // relay -> ws
    this._subscriptions = new Map(); // relay -> subId
    this._seenEvents = new Set(); // dedup by event id
    this._reconnectTimers = new Map();
    this._running = false;
  }

  /**
   * Start listening to all relays
   */
  start() {
    if (this._running) return;
    this._running = true;
    console.log('👁️  [NostrListener] Starting dispute monitor on', RELAYS.length, 'relays');
    
    for (const relay of RELAYS) {
      this._connectToRelay(relay);
    }
  }

  /**
   * Stop all connections
   */
  stop() {
    this._running = false;
    for (const [relay, ws] of this._connections) {
      try { ws.close(); } catch (e) { /* ignore */ }
    }
    for (const [_, timer] of this._reconnectTimers) {
      clearTimeout(timer);
    }
    this._connections.clear();
    this._subscriptions.clear();
    this._reconnectTimers.clear();
    console.log('🛑 [NostrListener] Stopped');
  }

  /**
   * Connect to a single relay with auto-reconnect
   */
  _connectToRelay(relayUrl) {
    if (!this._running) return;

    try {
      const ws = new WebSocket(relayUrl);
      
      ws.on('open', () => {
        console.log(`✅ [NostrListener] Connected to ${relayUrl}`);
        this._connections.set(relayUrl, ws);
        
        // Subscribe to dispute events
        const subId = `bro-agent-${Date.now().toString(36)}`;
        this._subscriptions.set(relayUrl, subId);
        
        for (const filter of DISPUTE_FILTERS) {
          const req = JSON.stringify(['REQ', subId, filter]);
          ws.send(req);
        }
      });

      ws.on('message', (data) => {
        try {
          const msg = JSON.parse(data.toString());
          this._handleMessage(relayUrl, msg);
        } catch (e) {
          // Non-JSON message, ignore
        }
      });

      ws.on('close', () => {
        console.log(`⚠️  [NostrListener] Disconnected from ${relayUrl}`);
        this._connections.delete(relayUrl);
        this._scheduleReconnect(relayUrl);
      });

      ws.on('error', (err) => {
        console.error(`❌ [NostrListener] Error on ${relayUrl}:`, err.message);
        try { ws.close(); } catch (e) { /* ignore */ }
      });

    } catch (err) {
      console.error(`❌ [NostrListener] Failed to connect to ${relayUrl}:`, err.message);
      this._scheduleReconnect(relayUrl);
    }
  }

  /**
   * Schedule reconnection with exponential backoff
   */
  _scheduleReconnect(relayUrl) {
    if (!this._running) return;
    
    const delay = 15000 + Math.random() * 10000; // 15-25s
    console.log(`🔄 [NostrListener] Reconnecting to ${relayUrl} in ${Math.round(delay/1000)}s`);
    
    const timer = setTimeout(() => {
      this._reconnectTimers.delete(relayUrl);
      this._connectToRelay(relayUrl);
    }, delay);
    
    this._reconnectTimers.set(relayUrl, timer);
  }

  /**
   * Handle incoming Nostr messages
   */
  _handleMessage(relayUrl, msg) {
    if (!Array.isArray(msg)) return;
    
    const [type, ...rest] = msg;
    
    if (type === 'EVENT' && rest.length >= 2) {
      const event = rest[1];
      this._handleEvent(relayUrl, event);
    }
    // EOSE, OK, NOTICE — ignore silently
  }

  /**
   * Process a single Nostr event
   */
  _handleEvent(relayUrl, event) {
    if (!event || !event.id) return;
    
    // Dedup
    if (this._seenEvents.has(event.id)) return;
    this._seenEvents.add(event.id);
    
    // Prevent memory leak — keep last 10K events
    if (this._seenEvents.size > 10000) {
      const arr = Array.from(this._seenEvents);
      this._seenEvents = new Set(arr.slice(-5000));
    }

    try {
      // Parse content as JSON
      let content;
      try {
        content = JSON.parse(event.content);
      } catch (e) {
        return; // Not a JSON event, skip
      }

      const eventType = content.type;
      
      if (eventType === 'bro_dispute') {
        console.log(`🔔 [NostrListener] New dispute detected: order ${content.orderId?.substring(0, 8)}... from ${relayUrl}`);
        this.emit('dispute', {
          eventId: event.id,
          pubkey: event.pubkey,
          createdAt: event.created_at,
          relay: relayUrl,
          dispute: content,
          tags: event.tags || [],
        });
      }
      
      else if (eventType === 'bro_dispute_evidence') {
        console.log(`📎 [NostrListener] New evidence for order ${content.orderId?.substring(0, 8)}... from ${relayUrl}`);
        this.emit('evidence', {
          eventId: event.id,
          pubkey: event.pubkey,
          createdAt: event.created_at,
          relay: relayUrl,
          evidence: content,
          tags: event.tags || [],
        });
      }
      
      else if (eventType === 'bro_dispute_resolution') {
        console.log(`⚖️  [NostrListener] Resolution for order ${content.orderId?.substring(0, 8)}... from ${relayUrl}`);
        this.emit('resolution', {
          eventId: event.id,
          pubkey: event.pubkey,
          createdAt: event.created_at,
          relay: relayUrl,
          resolution: content,
          tags: event.tags || [],
        });
      }
      
    } catch (e) {
      // Silently ignore malformed events
    }
  }

  /**
   * Get connection status
   */
  getStatus() {
    return {
      running: this._running,
      connectedRelays: Array.from(this._connections.keys()),
      totalRelays: RELAYS.length,
      seenEvents: this._seenEvents.size,
    };
  }
}

// Singleton
const nostrListener = new NostrListenerService();

module.exports = nostrListener;
