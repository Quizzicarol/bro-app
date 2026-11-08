// Pagamento único da wallet do cofre (devolução) — rodar NA máquina Fly. NÃO commitar.
(async () => {
  const invoice = process.argv[2];
  if (!invoice || !invoice.startsWith('ln')) { console.error('uso: node _vault_pay.js <invoice>'); process.exit(1); }
  try {
    const { defaultConfig, SdkBuilder } = require('@breeztech/breez-sdk-spark');
    const config = defaultConfig('mainnet');
    config.apiKey = process.env.BREEZ_API_KEY || null;
    const builder = await SdkBuilder.new(config, { type: 'mnemonic', mnemonic: process.env.VAULT_WALLET_MNEMONIC })
      .withDefaultStorage('/data/spark-vault');
    const sdk = await builder.build();

    const prepare = await sdk.prepareSendPayment({
      paymentRequest: { type: 'input', input: invoice },
    });
    console.log('PREPARE ok — fee lightning:', prepare.lightningFeeSats?.toString(), '| spark:', prepare.sparkTransferFeeSats?.toString());
    const resp = await sdk.sendPayment({
      prepareResponse: prepare,
      options: { type: 'bolt11Invoice', preferSpark: true, completionTimeoutSecs: 45 },
    });
    console.log('PAGO! id:', resp.payment.id, 'status:', resp.payment.status, 'amount:', resp.payment.amount?.toString());
    const info = await sdk.getInfo({});
    console.log('SALDO COFRE AGORA:', info.balanceSats?.toString());
    process.exit(0);
  } catch (e) {
    console.error('FALHA:', e.message);
    process.exit(1);
  }
})();
