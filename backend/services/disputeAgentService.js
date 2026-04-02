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

    // If LLM available, weight it more (60/40)
    if (llm && llm.suggestion) {
      const combinedConfidence = llm.confidence * 0.6 + heuristic.confidence * 0.4;
      
      // If both agree, boost confidence
      let finalConfidence = combinedConfidence;
      let finalSuggestion = llm.suggestion;
      
      if (heuristic.suggestion === llm.suggestion) {
        finalConfidence = Math.min(0.98, combinedConfidence * 1.15); // 15% boost
      } else if (llm.suggestion === 'escalate') {
        finalSuggestion = 'escalate';
        finalConfidence = Math.min(combinedConfidence, 0.5);
      }

      const tier = finalConfidence >= CONFIG.autoResolveThreshold ? 1 :
                   finalConfidence >= CONFIG.suggestThreshold ? 2 : 3;

      return {
        tier,
        suggestion: finalSuggestion,
        confidence: finalConfidence,
        reason: llm.reason || heuristic.reason,
        analysis: llm.analysis || '',
        riskFactors: llm.risk_factors || [],
      };
    }

    // Heuristic-only
    const tier = heuristic.confidence >= CONFIG.autoResolveThreshold ? 1 :
                 heuristic.confidence >= CONFIG.suggestThreshold ? 2 : 3;

    return {
      tier,
      suggestion: heuristic.suggestion || 'escalate',
      confidence: heuristic.confidence,
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
   */
  approveAnalysis(orderId) {
    const analysis = disputeAnalyses.get(orderId);
    if (!analysis) return null;
    
    analysis.resolvedBy = 'agent_approved';
    analysis.resolvedAt = new Date().toISOString();
    analysis.agentCorrect = true;
    disputeAnalyses.set(orderId, analysis);
    
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
