const { orders } = require('../models/database');
const { refundOrder } = require('./bitcoinService');

// In-process mutex to prevent concurrent expiration runs
let isRunning = false;

/**
 * Verifica ordens expiradas e processa refunds automaticamente.
 * Uses a mutex guard to prevent duplicate refunds from concurrent runs.
 */
async function checkExpiredOrders() {
  if (isRunning) {
    console.log('⏳ Expiration check already running, skipping');
    return 0;
  }
  isRunning = true;

  try {
    const now = new Date();
    let expiredCount = 0;

    for (const [orderId, order] of orders.entries()) {
      // Apenas ordens pending podem expirar
      if (order.status !== 'pending') continue;

      const expiresAt = new Date(order.expiresAt);
      
      // Verificar se expirou
      if (now > expiresAt) {
        // Atomically mark as expired BEFORE refund to prevent double-processing
        order.status = 'expired';
        order.expiredAt = now.toISOString();
        orders.set(orderId, order);

        console.log(`⏰ Ordem expirada detectada: ${orderId}`);
        
        try {
          // Fazer refund do Bitcoin
          await refundOrder(order);
          expiredCount++;
          console.log(`✅ Refund processado para ordem expirada: ${orderId}`);
        } catch (error) {
          console.error(`❌ Erro ao processar refund da ordem ${orderId}:`, error);
          // Mark as expired_refund_failed so it can be retried
          order.status = 'expired_refund_failed';
          orders.set(orderId, order);
        }
      }
    }

    if (expiredCount > 0) {
      console.log(`✅ ${expiredCount} ordem(ns) expirada(s) processada(s)`);
    }

    return expiredCount;
  } finally {
    isRunning = false;
  }
}

module.exports = {
  checkExpiredOrders
};
