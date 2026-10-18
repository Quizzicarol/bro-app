/**
 * disputeAgentService.js — AI-powered dispute analysis and resolution
 * 
 * Tier 1 (Auto): >90% confidence → resolve automatically
 * Tier 2 (Suggest): 60-90% → suggest to admin with explanation
 * Tier 3 (Escalate): <60% → flag for human review
 * 
 * v271 Phase 4: AI Dispute Agents
 */

const axios = require('axios');
const nostrListener = require('./nostrListenerService');
const db = require('../models/database');
const paymentVerifier = require('./paymentVerifier');
const fs = require('fs');
const path = require('path');

// v668: registro persistente de E2E vistos — o mesmo E2E em DUAS ordens é
// comprovante reutilizado (fraude certa). Sobrevive a restarts do servidor.
const E2E_REGISTRY_FILE = process.env.NODE_ENV === 'production'
  ? '/data/e2e_registry.json'
  : path.join(__dirname, '..', 'data', 'e2e_registry.json');
let e2eRegistry = new Map(); // e2e → { orderId, ts }
let e2eSaveTimer = null;

function _loadE2eRegistry() {
  try {
    if (!fs.existsSync(E2E_REGISTRY_FILE)) return;
    const data = JSON.parse(fs.readFileSync(E2E_REGISTRY_FILE, 'utf8'));
    for (const [e2e, rec] of Object.entries(data || {})) {
      if (rec && typeof rec === 'object') e2eRegistry.set(e2e, rec);
    }
    if (e2eRegistry.size > 0) console.log(`⚖️ [DisputeAgent] E2E registry: ${e2eRegistry.size} carregados`);
  } catch (e) {
    console.log(`[DisputeAgent] E2E registry load: ${e.message}`);
  }
}
_loadE2eRegistry();

function _scheduleE2eSave() {
  if (e2eSaveTimer) clearTimeout(e2eSaveTimer);
  e2eSaveTimer = setTimeout(() => {
    try {
      const dir = path.dirname(E2E_REGISTRY_FILE);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const out = Object.fromEntries(Array.from(e2eRegistry.entries()).slice(-20000));
      fs.writeFileSync(E2E_REGISTRY_FILE, JSON.stringify(out), { encoding: 'utf8', mode: 0o600 });
    } catch (e) {
      console.error(`[DisputeAgent] E2E registry save: ${e.message}`);
    }
  }, 5000);
}

/**
 * v668: cross-order E2E check. Se o E2E já foi visto em OUTRA ordem, é
 * comprovante reutilizado (fraude certa) — retorna finding high. Senão
 * registra e retorna null.
 */
function _checkE2eRegistry(e2e, dispute) {
  try {
    const orderId = dispute.order_id || dispute.orderId || '';
    const prev = e2eRegistry.get(e2e);
    if (prev && prev.orderId && orderId && prev.orderId !== orderId) {
      return {
        id: 'payment_e2e_reused_other_order',
        severity: 'high',
        detail: `E2E já usado em OUTRA ordem (${String(prev.orderId).substring(0, 8)}) — comprovante reutilizado`,
        scoreDelta: -0.45,
        favors: 'user',
      };
    }
    if (!prev) {
      e2eRegistry.set(e2e, { orderId, ts: Date.now() });
      if (e2eRegistry.size > 40000) {
        e2eRegistry = new Map(Array.from(e2eRegistry.entries()).slice(-20000));
      }
      _scheduleE2eSave();
    }
    return null;
  } catch (_) { return null; }
}

// ============================================
// Configuration
// ============================================

const CONFIG = {
  // LLM API (Claude by default, configurable)
  llmProvider: process.env.AGENT_LLM_PROVIDER || 'anthropic',
  llmApiKey: process.env.AGENT_LLM_API_KEY || '',
  llmModel: process.env.AGENT_LLM_MODEL || 'claude-sonnet-4-20250514',
  
  // Auto-resolution thresholds
  autoResolveThreshold: 0.90,  // Tier 1: auto-resolve
  suggestThreshold: 0.60,      // Tier 2: suggest to admin
  // Below suggestThreshold = Tier 3: escalate
  
  // Safety limits
  maxAutoResolvesPerDay: 20,
  maxDisputeAgeSecs: 7 * 24 * 3600, // 7 days
  
  // Recidivist thresholds
  recidivistLossCount: 3,
  recidivistHighRiskCount: 5,
};

// ============================================
// In-memory dispute store
// ============================================

// Map of orderId -> dispute analysis (capped to prevent memory exhaustion)
const disputeAnalyses = new Map();
const MAX_DISPUTE_ANALYSES = 1000;

// SECURITY v445: Track in-progress analyses to prevent concurrent LLM calls (with TTL)
const analysesInProgress = new Map(); // orderId -> timestamp
const IN_PROGRESS_TTL_MS = 120000; // 2 minutes max

// Counter for auto-resolves today
let autoResolvesToday = 0;
let autoResolveResetDate = new Date().toDateString();

// History of all analyses (for admin dashboard)
const analysisHistory = [];

// ============================================
// Analysis patterns (heuristic pre-LLM)
// ============================================

const HEURISTIC_RULES = [
  {
    id: 'proof_attached_provider_dispute',
    description: 'Provider opened dispute but proof image was attached by user',
    check: (dispute) => {
      return dispute.openedBy === 'provider' && 
             dispute.user_evidence_nip44 && 
             dispute.user_evidence_nip44.length > 100;
    },
    suggestion: 'resolved_user',
    confidence: 0.70,
    reason: 'Provedor abriu disputa mas usuário já enviou evidência (comprovante)',
  },
  {
    id: 'no_proof_user_dispute',
    description: 'User opened dispute with no evidence',
    check: (dispute) => {
      return dispute.openedBy === 'user' && 
             (!dispute.user_evidence_nip44 || dispute.user_evidence_nip44.length < 100) &&
             (!dispute.description || dispute.description.length < 20);
    },
    suggestion: 'resolved_provider',
    confidence: 0.55,
    reason: 'Usuário abriu disputa sem evidência e sem descrição detalhada',
  },
  {
    id: 'timeout_no_response',
    description: 'Provider did not respond - dispute about no response',
    check: (dispute) => {
      const reasons = ['Provedor não respondeu', 'provider_no_response'];
      return dispute.openedBy === 'user' && 
             reasons.some(r => (dispute.reason || '').includes(r));
    },
    suggestion: 'resolved_user',
    confidence: 0.75,
    reason: 'Disputa por falta de resposta do provedor',
  },
  {
    id: 'duplicate_dispute',
    description: 'Dispute for same order already resolved',
    check: (dispute, context) => {
      return !!context.alreadyResolved;
    },
    suggestion: 'skip',
    confidence: 1.0,
    reason: 'Disputa já foi resolvida anteriormente',
  },
];

// ============================================
// Core Agent Logic
// ============================================

class DisputeAgentService {
  constructor() {
    this._initialized = false;
  }

  /**
   * Initialize the agent — start listening for disputes
   */
  init() {
    if (this._initialized) return;
    this._initialized = true;

    // Reset auto-resolve counter daily
    setInterval(() => {
      const today = new Date().toDateString();
      if (today !== autoResolveResetDate) {
        autoResolvesToday = 0;
        autoResolveResetDate = today;
        console.log('🔄 [DisputeAgent] Auto-resolve counter reset');
      }
    }, 60000);

    // Listen for new disputes
    nostrListener.on('dispute', async (data) => {
      try {
        await this.analyzeDispute(data.dispute, {
          eventId: data.eventId,
          pubkey: data.pubkey,
          relay: data.relay,
        });
      } catch (err) {
        console.error('❌ [DisputeAgent] Error analyzing dispute:', err.message);
      }
    });

    // Listen for new evidence (re-analyze)
    nostrListener.on('evidence', async (data) => {
      try {
        const orderId = data.evidence?.orderId;
        if (orderId && disputeAnalyses.has(orderId)) {
          console.log(`📎 [DisputeAgent] New evidence for ${orderId.substring(0, 8)}, re-analyzing...`);
          const existing = disputeAnalyses.get(orderId);
          existing.evidenceCount = (existing.evidenceCount || 0) + 1;
          existing.needsReanalysis = true;
          disputeAnalyses.set(orderId, existing);
        }
      } catch (err) {
        console.error('❌ [DisputeAgent] Error processing evidence:', err.message);
      }
    });

    // Listen for manual resolutions (learn/track)
    nostrListener.on('resolution', (data) => {
      try {
        const orderId = data.resolution?.orderId;
        if (orderId && disputeAnalyses.has(orderId)) {
          const analysis = disputeAnalyses.get(orderId);
          analysis.humanResolution = data.resolution.resolution;
          analysis.resolvedAt = new Date().toISOString();
          analysis.resolvedBy = 'human';
          
          // Track accuracy
          if (analysis.suggestion === data.resolution.resolution) {
            analysis.agentCorrect = true;
            console.log(`✅ [DisputeAgent] Agent suggestion matched human resolution for ${orderId.substring(0, 8)}`);
          } else if (analysis.suggestion && analysis.suggestion !== 'skip') {
            analysis.agentCorrect = false;
            console.log(`❌ [DisputeAgent] Agent was wrong for ${orderId.substring(0, 8)}: suggested ${analysis.suggestion}, human chose ${data.resolution.resolution}`);
          }
          
          disputeAnalyses.set(orderId, analysis);
        }
      } catch (err) {
        console.error('❌ [DisputeAgent] Error tracking resolution:', err.message);
      }
    });

    // Start the Nostr listener
    nostrListener.start();
    console.log('🤖 [DisputeAgent] Initialized and listening for disputes');
  }

  /**
   * Analyze a dispute — heuristic first, then LLM if needed
   */
  async analyzeDispute(dispute, meta = {}) {
    const orderId = dispute.orderId;
    if (!orderId) return null;

    console.log(`🔍 [DisputeAgent] Analyzing dispute for order ${orderId.substring(0, 8)}...`);
    // SECURITY v445: Prevent concurrent analysis for same orderId (with TTL)
    if (analysesInProgress.has(orderId)) {
      const startedAt = analysesInProgress.get(orderId);
      if (Date.now() - startedAt < IN_PROGRESS_TTL_MS) {
        console.log(`   \u23F3 Analysis already in progress for ${orderId.substring(0, 8)}, skipping`);
        return disputeAnalyses.get(orderId) || null;
      }
      // TTL expired — stale entry, allow re-analysis
      analysesInProgress.delete(orderId);
    }
    // Check if already analyzed
    if (disputeAnalyses.has(orderId) && !disputeAnalyses.get(orderId).needsReanalysis) {
      console.log(`   ⏭️ Already analyzed, skipping`);
      return disputeAnalyses.get(orderId);
    }

    // SECURITY v445: Mark as in-progress to prevent concurrent LLM calls
    analysesInProgress.set(orderId, Date.now());
    try {
    // Build context
    const context = {
      alreadyResolved: disputeAnalyses.has(orderId) && disputeAnalyses.get(orderId).resolvedBy,
    };

    // v557 (Audit B2): Cross-check Nostr dispute payload vs backend DB row.
    // Tampering, missing escrow, or amount mismatches become findings.
    const dbFindings = this._buildDbFindings(dispute);

    // v557 (Audit B1): Detect order-flow anomalies from data already at hand
    // (timestamps, status transitions, evidence presence).
    const flowFindings = this._buildFlowFindings(dispute);

    // v557 (Audit B4): Structural validation of any payment code present in the
    // dispute payload (boleto linha digitável, PIX BR Code, PIX E2E).
    const paymentFindings = this._buildPaymentFindings(dispute);

    // Attach findings on the dispute object so they reach the LLM prompt and
    // confidence scoring downstream.
    dispute.db_findings = dbFindings;
    dispute.flow_findings = flowFindings;
    dispute.payment_findings = paymentFindings;

    // Step 1: Heuristic analysis
    const heuristicResult = this._runHeuristics(dispute, context);
    
    // Step 2: LLM analysis (if API key configured and heuristic confidence < auto-resolve)
    let llmResult = null;
    if (CONFIG.llmApiKey && heuristicResult.confidence < CONFIG.autoResolveThreshold) {
      llmResult = await this._runLlmAnalysis(dispute, heuristicResult);
    }

    // Step 3: Combine results
    const finalResult = this._combineResults(heuristicResult, llmResult, dispute);
    
    // Store analysis
    const analysis = {
      orderId,
      dispute: {
        reason: dispute.reason,
        description: dispute.description,
        openedBy: dispute.openedBy,
        amount_brl: dispute.amount_brl,
        amount_sats: dispute.amount_sats,
        payment_type: dispute.payment_type,
        hasEvidence: !!(dispute.user_evidence_nip44 && dispute.user_evidence_nip44.length > 100),
      },
      meta,
      heuristicResult,
      llmResult,
      dbFindings,
      flowFindings,
      paymentFindings,
      ...finalResult,
      analyzedAt: new Date().toISOString(),
      evidenceCount: 0,
      needsReanalysis: false,
    };

    // Evict oldest entry if at capacity (and not updating existing)
    if (!disputeAnalyses.has(orderId) && disputeAnalyses.size >= MAX_DISPUTE_ANALYSES) {
      const oldestKey = disputeAnalyses.keys().next().value;
      if (oldestKey) disputeAnalyses.delete(oldestKey);
    }

    disputeAnalyses.set(orderId, analysis);
    analysisHistory.push({ orderId, ...finalResult, analyzedAt: analysis.analyzedAt });
    
    // Keep history bounded
    if (analysisHistory.length > 500) {
      analysisHistory.splice(0, analysisHistory.length - 500);
    }

    // Log result
    const tierLabel = finalResult.tier === 1 ? 'AUTO' : finalResult.tier === 2 ? 'SUGGEST' : 'ESCALATE';
    console.log(`   📊 [DisputeAgent] ${tierLabel} | Confidence: ${(finalResult.confidence * 100).toFixed(0)}% | Suggestion: ${finalResult.suggestion} | ${finalResult.reason}`);

    // v557 (Audit A1): Tier 1 auto-execute candidate. The actual auto-resolve
    // path requires A2 (publishResolution helper with ADMIN_NSEC) and a
    // daily-rate limiter. Until A2 lands, log only.
    if (finalResult.tier === 1) {
      const todayKey = new Date().toISOString().slice(0, 10);
      this._autoResolvesByDay = this._autoResolvesByDay || {};
      const used = this._autoResolvesByDay[todayKey] || 0;
      if (used < CONFIG.maxAutoResolvesPerDay) {
        console.log(`🤖 [DisputeAgent] Tier 1 candidate (orderId=${orderId}) — A2 publish path NOT IMPLEMENTED. Skipping auto-execute. Daily quota ${used}/${CONFIG.maxAutoResolvesPerDay}.`);
      } else {
        console.warn(`🤖 [DisputeAgent] Tier 1 quota exhausted today (${used}/${CONFIG.maxAutoResolvesPerDay}) — would have downgraded to Tier 2.`);
      }
    }

    return analysis;
    } finally {
      analysesInProgress.delete(orderId);
    }
  }

  /**
   * Run heuristic rules
   */
  _runHeuristics(dispute, context) {
    let bestMatch = null;
    
    for (const rule of HEURISTIC_RULES) {
      try {
        if (rule.check(dispute, context)) {
          if (!bestMatch || rule.confidence > bestMatch.confidence) {
            bestMatch = {
              ruleId: rule.id,
              suggestion: rule.suggestion,
              confidence: rule.confidence,
              reason: rule.reason,
            };
          }
        }
      } catch (e) {
        // Rule evaluation error, skip
      }
    }

    return bestMatch || {
      ruleId: 'none',
      suggestion: null,
      confidence: 0,
      reason: 'Nenhuma regra heurística aplicável',
    };
  }

  // ============================================
  // v557 (Audit B2): DB cross-check findings
  // ============================================

  /**
   * Compares dispute payload (from Nostr) with backend DB row.
   * Detects tampering, missing escrow, or amount mismatches.
   * Returns array of findings (each: {id, severity, detail, scoreDelta}).
   */
  _buildDbFindings(dispute) {
    const out = [];
    const orderId = dispute.orderId;
    const order = (db.orders && typeof db.orders.get === 'function') ? db.orders.get(orderId) : null;
    const escrow = (db.escrows && typeof db.escrows.get === 'function') ? db.escrows.get(orderId) : null;

    if (!order) {
      out.push({
        id: 'db_order_missing',
        severity: 'medium',
        detail: 'Ordem não encontrada no DB do servidor (pode ser ordem antiga ou nunca registrada)',
        scoreDelta: -0.05,
      });
      return out;
    }

    // Amount BRL mismatch (>1 cent tolerance)
    if (dispute.amount_brl != null && order.amountBrl != null) {
      const a = parseFloat(dispute.amount_brl);
      const b = parseFloat(order.amountBrl);
      if (Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) > 0.01) {
        out.push({
          id: 'db_amount_brl_mismatch',
          severity: 'high',
          detail: `BRL Nostr=${a} DB=${b}`,
          scoreDelta: -0.30,
        });
      }
    }

    // Amount sats mismatch (>10 sats tolerance for rounding)
    if (dispute.amount_sats != null && order.amountSats != null) {
      const a = parseInt(dispute.amount_sats, 10);
      const b = parseInt(order.amountSats, 10);
      if (Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) > 10) {
        out.push({
          id: 'db_amount_sats_mismatch',
          severity: 'high',
          detail: `sats Nostr=${a} DB=${b}`,
          scoreDelta: -0.30,
        });
      }
    }

    // Payment type mismatch
    if (dispute.payment_type && order.billType && dispute.payment_type !== order.billType) {
      out.push({
        id: 'db_payment_type_mismatch',
        severity: 'high',
        detail: `tipo Nostr=${dispute.payment_type} DB=${order.billType}`,
        scoreDelta: -0.20,
      });
    }

    // Escrow record missing → dispute on a never-funded order
    if (!escrow) {
      out.push({
        id: 'db_no_escrow',
        severity: 'medium',
        detail: 'Sem registro de escrow no servidor — ordem pode não ter sido fundada',
        scoreDelta: -0.10,
      });
    }

    return out;
  }

  // ============================================
  // v557 (Audit B1): Flow-compliance findings
  // ============================================

  /**
   * Detects anomalies in the order timeline using data already in the dispute
   * payload + order DB. Future improvement (deferred): also fetch all kind
   * 30078/30079/30080/30081 events from relays to build a full timeline.
   *
   * Returns array of findings (each: {id, severity, detail, scoreDelta, favors}).
   */
  _buildFlowFindings(dispute) {
    const out = [];
    const order = (db.orders && typeof db.orders.get === 'function') ? db.orders.get(dispute.orderId) : null;
    const now = Date.now();
    const disputedAt = dispute.createdAt ? new Date(dispute.createdAt).getTime() : now;

    // Provider opened dispute but order was never accepted (no providerId)
    if (dispute.openedBy === 'provider' && order && !order.providerId) {
      out.push({
        id: 'flow_provider_dispute_unaccepted',
        severity: 'high',
        detail: 'Provedor abriu disputa em ordem que não foi aceita',
        scoreDelta: -0.20,
        favors: 'user',
      });
    }

    // User disputed before auto-liquidation window (36h after proof)
    if (order && order.proofReceivedAt) {
      const proofMs = new Date(order.proofReceivedAt).getTime();
      const hoursSinceProof = (disputedAt - proofMs) / 3600000;
      if (dispute.openedBy === 'user' && hoursSinceProof < 36) {
        out.push({
          id: 'flow_user_dispute_before_window',
          severity: 'low',
          detail: `Usuário abriu disputa ${hoursSinceProof.toFixed(1)}h após comprovante (janela auto-liq = 36h)`,
          scoreDelta: 0.0,
          favors: 'neutral',
        });
      }
      // Suspicious: proof submitted AFTER dispute was opened
      if (proofMs > disputedAt + 60000) {
        out.push({
          id: 'flow_proof_after_dispute',
          severity: 'high',
          detail: 'Comprovante submetido APÓS abertura da disputa',
          scoreDelta: -0.25,
          favors: 'user',
        });
      }
    }

    // No provider response within 72h
    if (order && order.acceptedAt) {
      const acceptedMs = new Date(order.acceptedAt).getTime();
      const hoursSinceAccept = (disputedAt - acceptedMs) / 3600000;
      if (hoursSinceAccept > 72 && !order.proofReceivedAt) {
        out.push({
          id: 'flow_no_provider_response_72h',
          severity: 'high',
          detail: `Provedor aceitou há ${hoursSinceAccept.toFixed(0)}h sem submeter comprovante`,
          scoreDelta: -0.15,
          favors: 'user',
        });
      }
    }

    // v-fix: Status-based comprovante check.
    // The mediator cannot read the happy-path comprovante (kind 30081, encrypted
    // to the user only), but the ORDER STATUS reveals whether one was ever sent:
    //   - stuck at pending/payment_received/accepted → NO comprovante (kind 30081)
    //   - reached awaiting_confirmation → comprovante WAS submitted, dispute is
    //     about its validity (verify E2E/amount/date, not its existence)
    const flowStatus = String(dispute.previous_status || (order && order.status) || '').toLowerCase();
    const comprovanteSubmitted = !!(order && order.proofReceivedAt) ||
      flowStatus === 'awaiting_confirmation' || flowStatus === 'completed' ||
      flowStatus === 'liquidated';
    const preProofStatuses = ['pending', 'payment_received', 'accepted'];

    if (dispute.openedBy === 'user' && preProofStatuses.includes(flowStatus) && !comprovanteSubmitted) {
      out.push({
        id: 'flow_no_comprovante_submitted',
        severity: 'high',
        detail: `Ordem parada em '${flowStatus}' sem comprovante (nenhum kind 30081) — provedor não entregou. Escrow deve retornar ao usuário`,
        scoreDelta: -0.20,
        favors: 'user',
      });
    }

    if (flowStatus === 'awaiting_confirmation') {
      out.push({
        id: 'flow_comprovante_awaiting_confirmation',
        severity: 'medium',
        detail: "Comprovante submetido e ordem chegou a 'awaiting_confirmation' — disputa é sobre a VALIDADE do comprovante; verificar E2E/valor/data antes de decidir",
        scoreDelta: 0.0,
        favors: 'neutral',
      });
    }

    // No evidence at all from disputer
    const hasEvidence = !!(dispute.user_evidence_nip44 && dispute.user_evidence_nip44.length > 100);
    if (!hasEvidence) {
      out.push({
        id: 'flow_no_evidence_from_disputer',
        severity: 'medium',
        detail: 'Quem abriu a disputa não anexou evidência',
        scoreDelta: -0.10,
        favors: dispute.openedBy === 'user' ? 'provider' : 'user',
      });
    }

    return out;
  }

  // ============================================
  // v557 (Audit B4): Payment code structural validation
  // ============================================

  /**
   * Validates structural shape of any payment code present in the dispute.
   * Looks at dispute.bill_code, dispute.pix_brcode, dispute.pix_e2e (and
   * common variants). Returns findings array compatible with other helpers.
   */
  _buildPaymentFindings(dispute) {
    const out = [];
    const codes = [
      { value: dispute.bill_code, source: 'bill_code' },
      { value: dispute.pix_brcode, source: 'pix_brcode' },
      { value: dispute.pix_e2e, source: 'pix_e2e' },
      { value: dispute.boleto_linha, source: 'boleto_linha' },
    ].filter(c => typeof c.value === 'string' && c.value.length > 0);

    for (const c of codes) {
      let res;
      try {
        res = paymentVerifier.verifyAny(c.value, {
          expectedAmountBrl: dispute.amount_brl,
          orderCreatedAt: dispute.createdAt,
          // v668: chave Pix esperada + janela temporal impossível
          // (E2E anterior à ordem = impossível; E2E futuro = forjado)
          expectedPixKey: dispute.pix_key || dispute.pixKey || null,
          notBeforeMs: dispute.createdAt ? new Date(dispute.createdAt).getTime() : null,
        });
      } catch (e) {
        out.push({
          id: 'payment_verify_error',
          severity: 'low',
          detail: `verifier crash em ${c.source}: ${e.message}`,
          scoreDelta: 0,
        });
        continue;
      }

      if (res.valid) {
        out.push({
          id: `payment_${res.type}_valid`,
          severity: 'info',
          detail: `${c.source}: ${res.type} estruturalmente válido`,
          scoreDelta: 0.05, // small boost when code passes checks
        });
      }
      // v668: cross-order — mesmo E2E em outra ordem = comprovante reutilizado
      if (res && res.type === 'pix_e2e' && res.ispb) {
        const dup = _checkE2eRegistry(c.value.trim(), dispute);
        if (dup) out.push(dup);
      }
      for (const f of (res.findings || [])) {
        out.push({
          id: `payment_${c.source}_${f.id}`,
          severity: f.severity,
          detail: f.detail,
          scoreDelta: f.severity === 'high' ? -0.15 : (f.severity === 'medium' ? -0.05 : 0),
        });
      }
    }

    return out;
  }

  /**
   * Run LLM analysis
   */
  async _runLlmAnalysis(dispute, heuristicResult) {
    try {
      const prompt = this._buildLlmPrompt(dispute, heuristicResult);
      
      let response;
      if (CONFIG.llmProvider === 'anthropic') {
        response = await this._callAnthropic(prompt);
      } else if (CONFIG.llmProvider === 'openai') {
        response = await this._callOpenAI(prompt);
      } else {
        console.warn('⚠️ [DisputeAgent] Unknown LLM provider:', CONFIG.llmProvider);
        return null;
      }

      return this._parseLlmResponse(response);
    } catch (err) {
      console.error('❌ [DisputeAgent] LLM analysis failed:', err.message);
      return null;
    }
  }

  /**
   * Sanitize user input for LLM prompt — prevent prompt injection.
   * Strips control chars, truncates, and escapes delimiters.
   */
  _sanitizeForPrompt(val, maxLen = 200) {
    if (val === null || val === undefined) return 'N/A';
    const str = String(val)
      .replace(/[\x00-\x1f\x7f]/g, '') // strip control chars
      .replace(/[`${}\\]/g, '')         // strip template/escape chars
      .replace(/["']/g, '')              // SECURITY v445: strip quotes to prevent JSON injection
      .replace(/[\[\]{}]/g, '')          // SECURITY v445: strip brackets/braces
      .trim();
    return str.length > maxLen ? str.substring(0, maxLen) + '…' : str;
  }

  /**
   * Build LLM prompt for dispute analysis.
   * SECURITY: All user-supplied fields are sanitized to prevent prompt injection.
   */
  _buildLlmPrompt(dispute, heuristicResult) {
    // Sanitize all user-controlled fields
    const s = (v, len) => this._sanitizeForPrompt(v, len);
    const safeOrderId = s(dispute.orderId, 64);
    const safePaymentType = s(dispute.payment_type, 20);
    const safeAmountBrl = s(dispute.amount_brl, 20);
    const safeAmountSats = s(dispute.amount_sats, 20);
    const safeOpenedBy = s(dispute.openedBy, 20);
    const safeReason = s(dispute.reason, 200);
    const safeDescription = s(dispute.description, 500);
    const safePrevStatus = s(dispute.previous_status, 30);
    const hasEvidence = dispute.user_evidence_nip44 ? 'SIM' : 'NÃO';
    const hasPixKey = dispute.pix_key ? 'Informada' : 'Não informada';

    // v557 (Audit B1/B2/B4): Surface automated findings to the LLM so its
    // reasoning is grounded in DB cross-checks, flow anomalies and payment
    // code structural validation — not just user prose.
    const fmtFindings = (arr) => {
      if (!Array.isArray(arr) || arr.length === 0) return 'nenhum';
      return arr.map(f => `[${f.severity || 'info'}] ${s(f.detail, 200)}`).join('; ');
    };
    const dbFindingsStr = fmtFindings(dispute.db_findings);
    const flowFindingsStr = fmtFindings(dispute.flow_findings);
    const paymentFindingsStr = fmtFindings(dispute.payment_findings);

    return `Você é um agente de mediação de disputas para o Bro, um app P2P de pagamento de contas no Brasil usando Bitcoin/Lightning.

CONTEXTO DA DISPUTA:
- Ordem: ${safeOrderId}
- Tipo de pagamento: ${safePaymentType}
- Valor: R$ ${safeAmountBrl} (${safeAmountSats} sats)
- Aberta por: ${safeOpenedBy}
- Motivo: ${safeReason}
- Descrição: ${safeDescription}
- Status anterior: ${safePrevStatus}
- Tem evidência (foto/comprovante): ${hasEvidence}
- Chave Pix do pagamento: ${hasPixKey}

ANÁLISE HEURÍSTICA PRÉVIA:
- Regra: ${s(heuristicResult.ruleId, 50)}
- Sugestão: ${s(heuristicResult.suggestion, 30) || 'Nenhuma'}
- Confiança: ${(heuristicResult.confidence * 100).toFixed(0)}%
- Razão: ${s(heuristicResult.reason, 200)}

ACHADOS AUTOMÁTICOS (verificações estruturais — NÃO são opinião):
- Cruzamento com DB do servidor: ${dbFindingsStr}
- Conformidade do fluxo (timestamps/status): ${flowFindingsStr}
- Validação dos códigos de pagamento: ${paymentFindingsStr}

REGRAS DE MEDIAÇÃO:
1. Se o provedor não respondeu em tempo hábil, favorecer o USUÁRIO
2. Se o usuário não tem evidência de pagamento, favorecer o PROVEDOR
3. Se há comprovante de pagamento válido COM código de autenticação e E2E, favorecer o USUÁRIO
4. Se a disputa é sobre valor incorreto, analisar se a diferença é significativa
5. Se ambas as partes têm evidências conflitantes, ESCALAR para humano
6. Proteger o lado mais vulnerável quando em dúvida
7. Uma IMAGEM de comprovante sem código E2E e sem código de autenticação NÃO é prova válida de pagamento PIX
8. Todo comprovante PIX real contém: código de autenticação, E2E, nome do destinatário, valor, data/hora
9. Se o provedor enviou apenas imagem sem dados verificáveis, considerar como evidência FRACA ou fabricada

Responda APENAS no formato JSON:
{
  "suggestion": "resolved_user" | "resolved_provider" | "escalate",
  "confidence": 0.0 a 1.0,
  "reason": "explicação curta em português",
  "analysis": "análise detalhada em português (2-3 frases)",
  "risk_factors": ["fator1", "fator2"]
}`;
  }

  /**
   * Call Anthropic Claude API
   */
  async _callAnthropic(prompt) {
    const response = await axios.post('https://api.anthropic.com/v1/messages', {
      model: CONFIG.llmModel,
      max_tokens: 500,
      messages: [{ role: 'user', content: prompt }],
    }, {
      headers: {
        'x-api-key': CONFIG.llmApiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      timeout: 30000,
    });

    return response.data?.content?.[0]?.text || '';
  }

  /**
   * Call OpenAI API
   */
  async _callOpenAI(prompt) {
    const response = await axios.post('https://api.openai.com/v1/chat/completions', {
      model: CONFIG.llmModel,
      max_tokens: 500,
      messages: [{ role: 'user', content: prompt }],
    }, {
      headers: {
        'Authorization': `Bearer ${CONFIG.llmApiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000,
    });

    return response.data?.choices?.[0]?.message?.content || '';
  }

  /**
   * Parse LLM response
   */
  _parseLlmResponse(text) {
    try {
      // Extract JSON from response (handle markdown code blocks)
      const jsonMatch = text.match(/\{[\s\S]*\}/);
      if (!jsonMatch) return null;
      
      const parsed = JSON.parse(jsonMatch[0]);
      
      // Validate required fields
      if (!parsed.suggestion || typeof parsed.confidence !== 'number') return null;
      
      // Clamp confidence
      parsed.confidence = Math.max(0, Math.min(1, parsed.confidence));
      
      // SECURITY v445: Validate string fields from LLM response
      parsed.reason = typeof parsed.reason === 'string' ? parsed.reason.substring(0, 500) : 'N/A';
      parsed.analysis = typeof parsed.analysis === 'string' ? parsed.analysis.substring(0, 1000) : 'N/A';
      parsed.risk_factors = Array.isArray(parsed.risk_factors) 
        ? parsed.risk_factors.filter(f => typeof f === 'string').slice(0, 10) 
        : [];
      
      // Validate suggestion
      if (!['resolved_user', 'resolved_provider', 'escalate'].includes(parsed.suggestion)) {
        parsed.suggestion = 'escalate';
        parsed.confidence = 0.3;
      }

      return parsed;
    } catch (e) {
      console.error('❌ [DisputeAgent] Failed to parse LLM response:', e.message);
      return null;
    }
  }

  /**
   * Combine heuristic and LLM results
   *
   * v557 (Audit B1/B2/B4 + A11): Apply scoreDelta from automated findings
   * (DB cross-check, flow compliance, payment code validation) AND enforce a
   * hard guard for Tier 1: requires heuristic ≥ 0.80 AND llm ≥ 0.85, otherwise
   * demote to Tier 2 (admin must approve). Findings flagged as `favors:'user'`
   * or `favors:'provider'` may also override the suggestion when severity=high.
   */
  _combineResults(heuristic, llm, dispute) {
    // If heuristic says skip (already resolved), honor it
    if (heuristic.suggestion === 'skip') {
      return {
        tier: 0,
        suggestion: 'skip',
        confidence: 1.0,
        reason: heuristic.reason,
        analysis: 'Disputa já resolvida',
        riskFactors: [],
      };
    }

    // Aggregate scoreDelta from all findings on the dispute
    const allFindings = [
      ...(dispute.db_findings || []),
      ...(dispute.flow_findings || []),
      ...(dispute.payment_findings || []),
    ];
    const totalDelta = allFindings.reduce((acc, f) => acc + (Number(f.scoreDelta) || 0), 0);
    const clampedDelta = Math.max(-0.6, Math.min(0.2, totalDelta));

    // Detect strong directional signal from flow findings
    const strongFlowFavor = (dispute.flow_findings || [])
      .filter(f => f.severity === 'high' && (f.favors === 'user' || f.favors === 'provider'))
      .map(f => f.favors);
    const flowOverride = strongFlowFavor.length > 0 ? strongFlowFavor[0] : null;

    // If LLM available, weight it more (60/40)
    if (llm && llm.suggestion) {
      const combinedConfidence = llm.confidence * 0.6 + heuristic.confidence * 0.4;

      let finalConfidence = combinedConfidence;
      let finalSuggestion = llm.suggestion;

      if (heuristic.suggestion === llm.suggestion) {
        finalConfidence = Math.min(0.98, combinedConfidence * 1.15);
      } else if (llm.suggestion === 'escalate') {
        finalSuggestion = 'escalate';
        finalConfidence = Math.min(combinedConfidence, 0.5);
      }

      // Apply automated findings delta
      finalConfidence = Math.max(0, Math.min(0.98, finalConfidence + clampedDelta));

      // Strong flow override — high-severity timeline anomaly trumps text reasoning
      if (flowOverride === 'user' && finalSuggestion !== 'resolved_user') {
        finalSuggestion = 'resolved_user';
        finalConfidence = Math.min(finalConfidence, 0.75);
      } else if (flowOverride === 'provider' && finalSuggestion !== 'resolved_provider') {
        finalSuggestion = 'resolved_provider';
        finalConfidence = Math.min(finalConfidence, 0.75);
      }

      // Naive tier
      let tier = finalConfidence >= CONFIG.autoResolveThreshold ? 1 :
                 finalConfidence >= CONFIG.suggestThreshold ? 2 : 3;

      // A11 HARD GUARD: never auto-resolve (Tier 1) unless BOTH the heuristic
      // and LLM independently expressed strong agreement. This prevents the
      // 60/40 weighting + 15% boost from synthesizing a Tier 1 from two
      // mediocre signals.
      if (tier === 1) {
        const passesGuard =
          heuristic.confidence >= 0.80 &&
          llm.confidence >= 0.85 &&
          heuristic.suggestion === llm.suggestion &&
          finalSuggestion !== 'escalate';
        if (!passesGuard) {
          tier = 2;
        }
      }

      return {
        tier,
        suggestion: finalSuggestion,
        confidence: finalConfidence,
        reason: llm.reason || heuristic.reason,
        analysis: llm.analysis || '',
        riskFactors: llm.risk_factors || [],
      };
    }

    // Heuristic-only path
    let finalConfidence = Math.max(0, Math.min(0.98, heuristic.confidence + clampedDelta));
    let finalSuggestion = heuristic.suggestion || 'escalate';

    if (flowOverride === 'user' && finalSuggestion !== 'resolved_user') {
      finalSuggestion = 'resolved_user';
      finalConfidence = Math.min(finalConfidence, 0.70);
    } else if (flowOverride === 'provider' && finalSuggestion !== 'resolved_provider') {
      finalSuggestion = 'resolved_provider';
      finalConfidence = Math.min(finalConfidence, 0.70);
    }

    let tier = finalConfidence >= CONFIG.autoResolveThreshold ? 1 :
               finalConfidence >= CONFIG.suggestThreshold ? 2 : 3;

    // A11 HARD GUARD (heuristic-only): never Tier 1 without LLM corroboration.
    // Without an LLM second opinion we don't have the dual-signal needed for
    // automatic execution.
    if (tier === 1) tier = 2;

    return {
      tier,
      suggestion: finalSuggestion,
      confidence: finalConfidence,
      reason: heuristic.reason,
      analysis: '',
      riskFactors: [],
    };
  }

  // ============================================
  // Admin API methods
  // ============================================

  /**
   * Get all pending analyses (for admin dashboard)
   */
  getPendingAnalyses() {
    const pending = [];
    for (const [orderId, analysis] of disputeAnalyses) {
      if (!analysis.resolvedBy && analysis.suggestion !== 'skip') {
        pending.push({
          orderId,
          tier: analysis.tier,
          suggestion: analysis.suggestion,
          confidence: analysis.confidence,
          reason: analysis.reason,
          analysis: analysis.analysis || '',
          riskFactors: analysis.riskFactors || [],
          dispute: analysis.dispute,
          analyzedAt: analysis.analyzedAt,
          evidenceCount: analysis.evidenceCount || 0,
          needsReanalysis: analysis.needsReanalysis || false,
        });
      }
    }
    
    // Sort: Tier 1 first, then by confidence desc
    pending.sort((a, b) => {
      if (a.tier !== b.tier) return a.tier - b.tier;
      return b.confidence - a.confidence;
    });
    
    return pending;
  }

  /**
   * Get analysis for a specific order
   */
  getAnalysis(orderId) {
    return disputeAnalyses.get(orderId) || null;
  }

  /**
   * Admin approves agent suggestion
   *
   * v557 (Audit A2): TODO — actually publish a kind 30080 `bro-resolucao`
   * audit event and a kind 30081 completion to the relays so all clients
   * converge on the resolution. This requires:
   *   - process.env.ADMIN_NSEC : nsec1... key for the platform admin pubkey
   *   - A small helper (similar to nostrListenerService) that signs with the
   *     admin key and publishes to the configured relay set.
   *   - Encrypted (NIP-44) DM to the loser explaining the decision.
   * Until then, this only flips an in-memory flag — the apps still need a
   * human to manually resolve via the regular admin UI.
   */
  approveAnalysis(orderId) {
    const analysis = disputeAnalyses.get(orderId);
    if (!analysis) return null;

    analysis.resolvedBy = 'agent_approved';
    analysis.resolvedAt = new Date().toISOString();
    analysis.agentCorrect = true;
    disputeAnalyses.set(orderId, analysis);

    // A2 stub: signal that real publish path is pending
    if (!process.env.ADMIN_NSEC) {
      console.warn('⚠️ [DisputeAgent] approveAnalysis: ADMIN_NSEC not set — resolution NOT published to Nostr (admin must resolve manually). orderId=' + orderId);
    } else {
      console.warn('⚠️ [DisputeAgent] approveAnalysis: ADMIN_NSEC present but publishResolution() helper not yet implemented — resolution NOT published. orderId=' + orderId);
    }

    return analysis;
  }

  /**
   * Admin rejects agent suggestion
   */
  rejectAnalysis(orderId, humanDecision) {
    const analysis = disputeAnalyses.get(orderId);
    if (!analysis) return null;
    
    analysis.resolvedBy = 'human_override';
    analysis.humanResolution = humanDecision;
    analysis.resolvedAt = new Date().toISOString();
    analysis.agentCorrect = false;
    disputeAnalyses.set(orderId, analysis);
    
    return analysis;
  }

  /**
   * Get agent stats
   */
  getStats() {
    let total = 0, correct = 0, incorrect = 0, pending = 0;
    let tier1 = 0, tier2 = 0, tier3 = 0;
    
    for (const [, analysis] of disputeAnalyses) {
      if (analysis.suggestion === 'skip') continue;
      total++;
      
      if (analysis.tier === 1) tier1++;
      else if (analysis.tier === 2) tier2++;
      else tier3++;
      
      if (analysis.resolvedBy) {
        if (analysis.agentCorrect) correct++;
        else if (analysis.agentCorrect === false) incorrect++;
      } else {
        pending++;
      }
    }

    return {
      total,
      pending,
      resolved: total - pending,
      accuracy: total - pending > 0 ? (correct / (correct + incorrect) * 100).toFixed(1) + '%' : 'N/A',
      correct,
      incorrect,
      tiers: { tier1, tier2, tier3 },
      autoResolvesToday,
      listener: nostrListener.getStatus(),
      config: {
        llmProvider: CONFIG.llmProvider,
        llmConfigured: !!CONFIG.llmApiKey,
        autoResolveThreshold: CONFIG.autoResolveThreshold,
        suggestThreshold: CONFIG.suggestThreshold,
      },
    };
  }
}

// Singleton
const disputeAgent = new DisputeAgentService();

module.exports = disputeAgent;
