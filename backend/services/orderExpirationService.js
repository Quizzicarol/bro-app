const { orders } = require('../models/database');
const { refundOrder } = require('./bitcoinService');

/**
 * Verifica ordens expiradas e processa refunds automaticamente
 */
async function checkExpiredOrders() {
  const now = new Date();
  let expiredCount = 0;

  for (const [orderId, order] of orders.entries()) {
    // Apenas ordens pending podem expirar
    if (order.status !== 'pending') continue;

    const expiresAt = new Date(order.expiresAt);
    
    // Verificar se expirou
    if (now > expiresAt) {
      console.log(`⏰ Ordem expirada detectada: ${orderId}`);
      
      try {
        // Fazer refund do Bitcoin
        await refundOrder(order);
        
        // Atualizar status
        order.status = 'expired';
        order.expiredAt = now.toISOString();
        orders.set(orderId, order);
        
        expiredCount++;
        console.log(`✅ Refund processado para ordem expirada: ${orderId}`);
        
      } catch (error) {
        console.error(`❌ Erro ao processar refund da ordem ${orderId}:`, error);
      }
    }
  }

  if (expiredCount > 0) {
    console.log(`✅ ${expiredCount} ordem(ns) expirada(s) processada(s)`);
  } else {
    console.log('✓ Nenhuma ordem expirada encontrada');
  }

  return expiredCount;
}

module.exports = {
  checkExpiredOrders
};
