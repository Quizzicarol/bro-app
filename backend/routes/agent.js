/**
 * agent.js — API routes for the AI dispute agent
 * 
 * All routes require NIP-98 auth + admin pubkey verification.
 * 
 * v271 Phase 4: AI Dispute Agents
 */

const express = require('express');
const router = express.Router();
const disputeAgent = require('../services/disputeAgentService');

// Admin pubkey from env
const ADMIN_PUBKEY = process.env.ADMIN_PUBKEY || '';

// SECURITY v445: Validate ADMIN_PUBKEY format at startup
if (ADMIN_PUBKEY && !/^[0-9a-f]{64}$/.test(ADMIN_PUBKEY)) {
  console.error('\u274C ADMIN_PUBKEY is not a valid 64-char hex pubkey! Agent routes will be disabled.');
}

/**
 * Middleware: Verify caller is the admin
 */
function requireAdmin(req, res, next) {
  if (!ADMIN_PUBKEY || !/^[0-9a-f]{64}$/.test(ADMIN_PUBKEY)) {
    return res.status(503).json({ error: 'ADMIN_PUBKEY not configured or invalid' });
  }
  if (req.verifiedPubkey !== ADMIN_PUBKEY) {
    return res.status(403).json({ error: 'Admin access required' });
  }
  next();
}

// ============================================
// Routes
// ============================================

/**
 * GET /agent/status — Agent status and stats
 */
router.get('/status', requireAdmin, (req, res) => {
  try {
    const stats = disputeAgent.getStats();
    res.json({ success: true, ...stats });
  } catch (error) {
    console.error('Error getting agent status:', error);
    res.status(500).json({ error: 'Failed to get agent status' });
  }
});

/**
 * GET /agent/pending — List pending dispute analyses
 */
router.get('/pending', requireAdmin, (req, res) => {
  try {
    const pending = disputeAgent.getPendingAnalyses();
    res.json({
      success: true,
      count: pending.length,
      analyses: pending,
    });
  } catch (error) {
    console.error('Error getting pending analyses:', error);
    res.status(500).json({ error: 'Failed to get pending analyses' });
  }
});

/**
 * GET /agent/analysis/:orderId — Get analysis for specific order
 */
router.get('/analysis/:orderId', requireAdmin, (req, res) => {
  try {
    const analysis = disputeAgent.getAnalysis(req.params.orderId);
    if (!analysis) {
      return res.status(404).json({ error: 'No analysis found for this order' });
    }
    res.json({ success: true, analysis });
  } catch (error) {
    console.error('Error getting analysis:', error);
    res.status(500).json({ error: 'Failed to get analysis' });
  }
});

/**
 * POST /agent/approve — Admin approves agent suggestion
 */
router.post('/approve', requireAdmin, (req, res) => {
  try {
    const { orderId } = req.body;
    if (!orderId) {
      return res.status(400).json({ error: 'orderId is required' });
    }

    const result = disputeAgent.approveAnalysis(orderId);
    if (!result) {
      return res.status(404).json({ error: 'No analysis found for this order' });
    }

    console.log(`✅ [Agent] Admin approved suggestion for ${orderId.substring(0, 8)}: ${result.suggestion}`);
    res.json({ success: true, result });
  } catch (error) {
    console.error('Error approving analysis:', error);
    res.status(500).json({ error: 'Failed to approve analysis' });
  }
});

/**
 * POST /agent/reject — Admin rejects agent suggestion
 */
router.post('/reject', requireAdmin, (req, res) => {
  try {
    const { orderId, humanDecision } = req.body;
    if (!orderId || !humanDecision) {
      return res.status(400).json({ error: 'orderId and humanDecision are required' });
    }
    if (!['resolved_user', 'resolved_provider'].includes(humanDecision)) {
      return res.status(400).json({ error: 'humanDecision must be resolved_user or resolved_provider' });
    }

    const result = disputeAgent.rejectAnalysis(orderId, humanDecision);
    if (!result) {
      return res.status(404).json({ error: 'No analysis found for this order' });
    }

    console.log(`❌ [Agent] Admin rejected suggestion for ${orderId.substring(0, 8)}: agent said ${result.suggestion}, human chose ${humanDecision}`);
    res.json({ success: true, result });
  } catch (error) {
    console.error('Error rejecting analysis:', error);
    res.status(500).json({ error: 'Failed to reject analysis' });
  }
});

/**
 * POST /agent/analyze — Manually trigger analysis for an order
 */
router.post('/analyze', requireAdmin, (req, res) => {
  try {
    const { dispute } = req.body;
    if (!dispute || !dispute.orderId) {
      return res.status(400).json({ error: 'dispute object with orderId is required' });
    }

    // Validate orderId format (max 64 chars, alphanumeric + hyphens/underscores)
    if (typeof dispute.orderId !== 'string' || dispute.orderId.length > 64 || !/^[a-zA-Z0-9_-]+$/.test(dispute.orderId)) {
      return res.status(400).json({ error: 'Invalid orderId format' });
    }

    // Run async analysis
    disputeAgent.analyzeDispute(dispute, { manual: true, requestedBy: req.verifiedPubkey })
      .then(result => {
        if (result) {
          console.log(`🔍 [Agent] Manual analysis for ${dispute.orderId.substring(0, 8)}: ${result.suggestion} (${(result.confidence * 100).toFixed(0)}%)`);
        }
      })
      .catch(err => {
        console.error('❌ [Agent] Manual analysis error:', err.message);
      });

    res.json({ success: true, message: 'Analysis started. Check /agent/analysis/:orderId for results.' });
  } catch (error) {
    console.error('Error triggering analysis:', error);
    res.status(500).json({ error: 'Failed to trigger analysis' });
  }
});

module.exports = router;
