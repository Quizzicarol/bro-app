/**
 * Cofre HODL — garantia REAL do provedor, travada num HODL invoice pago à
 * wallet Spark do servidor (branch feature/hodl-collateral; NÃO vai pra
 * produção sem a Carol aprovar).
 *
 * Fluxo:
 *   1. Provedor ativa tier → app pede POST /hodl/lock-invoice
 *   2. Servidor cria invoice bolt11 HODL (preimage fica criptografado aqui)
 *   3. Provedor PAGA o invoice → sats ficam travados (waitingForPreimage)
 *   4. Caminho feliz: app renova antes do vencimento (novo HODL encadeado)
 *   5. Liberar garantia: provedor pede → admin aprova → servidor NÃO recolhe
 *      e a renovação para → os sats voltam sozinhos no vencimento
 *      (o SDK não tem cancelamento antecipado — devolução = expiry)
 *   6. Slash: admin recolhe com claimHtlcPayment(preimage) → garantia vai
 *      pro servidor (cobrir prejuízo causado pelo provedor)
 *
 * Segredos (Fly secrets, NUNCA no repo):
 *   VAULT_WALLET_MNEMONIC — seed da wallet Spark do cofre
 *   VAULT_MASTER_KEY      — chave pra criptografar preimages em repouso
 *   BREEZ_API_KEY         — já existe
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const pushService = require('./pushService');

const VAULT_FILE = process.env.NODE_ENV === 'production'
  ? '/data/hodl_vault.json'
  : path.join(__dirname, '..', 'data', 'hodl_vault.json');

const STORAGE_DIR = process.env.NODE_ENV === 'production'
  ? '/data/spark-vault'
  : path.join(__dirname, '..', 'data', 'spark-vault');

// Vencimento padrão da garantia: 7 dias (renovado automaticamente pelo app
// enquanto o tier estiver ativo). Admin pode testar com expiry curto.
const DEFAULT_EXPIRY_SECS = 7 * 24 * 60 * 60;
const MIN_TEST_EXPIRY_SECS = 15 * 60; // 15min — só pra admin testar

// Renovar quando faltar menos que isso pro vencimento
const RENEW_WINDOW_SECS = 24 * 60 * 60; // 24h

const POLL_INTERVAL_MS = 30 * 1000;

class HodlVaultService {
  constructor() {
    this._sdk = null;
    this._initializing = null;
    this._records = new Map(); // paymentHash → record
    this._pollTimer = null;
    this._masterKey = null; // Buffer de 32 bytes
    this._loadState();
  }

  // ── Persistência ──────────────────────────────────────────────────────

  _loadState() {
    try {
      if (fs.existsSync(VAULT_FILE)) {
        const raw = JSON.parse(fs.readFileSync(VAULT_FILE, 'utf8'));
        for (const r of raw.records || []) this._records.set(r.paymentHash, r);
        console.log(`🔐 [Vault] ${this._records.size} garantia(s) carregadas`);
      }
    } catch (e) {
      console.error(`⚠️ [Vault] Falha ao carregar estado: ${e.message}`);
    }
  }

  _saveState() {
    try {
      fs.mkdirSync(path.dirname(VAULT_FILE), { recursive: true });
      const tmp = VAULT_FILE + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify({ records: Array.from(this._records.values()) }, null, 2));
      fs.renameSync(tmp, VAULT_FILE);
    } catch (e) {
      console.error(`⚠️ [Vault] Falha ao salvar estado: ${e.message}`);
    }
  }

  // ── Criptografia dos preimages (AES-256-GCM com VAULT_MASTER_KEY) ─────

  _getMasterKey() {
    if (this._masterKey) return this._masterKey;
    const raw = process.env.VAULT_MASTER_KEY || '';
    if (raw.length < 32) throw new Error('VAULT_MASTER_KEY ausente/curta (mín 32 chars)');
    this._masterKey = crypto.createHash('sha256').update(raw).digest();
    return this._masterKey;
  }

  _encryptPreimage(preimageHex) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', this._getMasterKey(), iv);
    const enc = Buffer.concat([cipher.update(preimageHex, 'utf8'), cipher.final()]);
    const tag = cipher.getAuthTag();
    return `${iv.toString('hex')}:${tag.toString('hex')}:${enc.toString('hex')}`;
  }

  _decryptPreimage(blob) {
    const [ivHex, tagHex, dataHex] = blob.split(':');
    const decipher = crypto.createDecipheriv('aes-256-gcm', this._getMasterKey(), Buffer.from(ivHex, 'hex'));
    decipher.setAuthTag(Buffer.from(tagHex, 'hex'));
    return Buffer.concat([decipher.update(Buffer.from(dataHex, 'hex')), decipher.final()]).toString('utf8');
  }

  // ── SDK Spark (lazy — backend sobe mesmo sem os segredos) ─────────────

  async _getSdk() {
    if (this._sdk) return this._sdk;
    if (this._initializing) return this._initializing;
    this._initializing = (async () => {
      try {
        // Seed da wallet do cofre: mnemonic OU entropia hex (32 bytes).
        let seed;
        const mnemonic = process.env.VAULT_WALLET_MNEMONIC;
        const entropyHex = process.env.VAULT_WALLET_ENTROPY;
        if (mnemonic) {
          seed = { type: 'mnemonic', mnemonic };
        } else if (entropyHex && /^[0-9a-f]{64}$/i.test(entropyHex)) {
          seed = Array.from(Buffer.from(entropyHex, 'hex'));
          seed.type = 'entropy';
        } else {
          throw new Error('VAULT_WALLET_MNEMONIC/ENTROPY não configurado — cofre desabilitado');
        }
        const { defaultConfig, SdkBuilder } = require('@breeztech/breez-sdk-spark');
        const config = defaultConfig('mainnet');
        config.apiKey = process.env.BREEZ_API_KEY || null;
        // IMPORTANTE: withDefaultStorage CONSOME o builder (wasm-bindgen) e
        // retorna um NOVO — usar o antigo dá "null pointer passed to rust"
        // e derruba o processo inteiro (visto em produção 05/11).
        const builder = await SdkBuilder.new(config, seed).withDefaultStorage(STORAGE_DIR);
        this._sdk = await builder.build();
        console.log('🔐 [Vault] Wallet Spark do cofre conectada');
        this._startPolling();
        return this._sdk;
      } catch (e) {
        console.error(`❌ [Vault] init falhou: ${e?.message || e}`);
        this._sdk = null;
        throw new Error(`cofre indisponível: ${e?.message || e}`);
      }
    })();
    try {
      return await this._initializing;
    } finally {
      this._initializing = null;
    }
  }

  /** Watchtower injetado pelo server.js — fonte das pendências do provedor. */
  attachWatchtower(wt) { this._watchtower = wt; }

  /** Sobe o SDK + poller no boot (sem esperar a 1ª chamada). Sem segredos,
   * falha em silêncio — o cofre fica desabilitado e o resto funciona. */
  warmup() {
    this._getSdk().catch((e) => console.log(`ℹ️ [Vault] warmup: ${e.message}`));
  }

  // ── API pública do serviço ────────────────────────────────────────────

  /** Garantia ATIVA de um provedor (qualquer status não-final). */
  getActiveForProvider(providerPubkey) {
    for (const r of this._records.values()) {
      if (r.providerPubkey !== providerPubkey) continue;
      if (['awaiting_payment', 'locked', 'release_pending'].includes(r.status)) return r;
    }
    return null;
  }

  listAll() {
    return Array.from(this._records.values())
      .sort((a, b) => b.createdAt - a.createdAt)
      .map(r => this._publicRecord(r));
  }

  _publicRecord(r) {
    // NUNCA expor o preimage criptografado
    const { preimageEnc, ...pub } = r;
    return pub;
  }

  /**
   * Cria o invoice HODL da garantia. Um provedor = uma garantia ativa por vez.
   * expirySecs custom só é permitido pro ADMIN (testes com ciclos curtos).
   */
  async createLockInvoice({ providerPubkey, tierId, tierName, amountSats, expirySecs, upgrade = false }) {
    const existing = this.getActiveForProvider(providerPubkey);
    if (existing) {
      // Idempotente: se já tem garantia ativa do MESMO tier, devolve o invoice
      // atual (app pode ter perdido a resposta anterior).
      if (existing.status === 'awaiting_payment' && existing.tierId === tierId) {
        return { invoice: existing.invoice, paymentHash: existing.paymentHash, reused: true };
      }
      // UPGRADE/DOWNGRADE de tier: a garantia antiga é liberada na hora (os
      // sats voltam no vencimento DELA) e a nova é criada. Sem admin — o
      // provedor segue coberto durante a transição (a antiga continua
      // travada até o vencimento, então nunca há janela sem garantia).
      if (upgrade === true && existing.status === 'locked' && existing.tierId !== tierId) {
        existing.status = 'released';
        existing.history.push({ at: Math.floor(Date.now() / 1000), event: 'released_for_upgrade', toTier: tierId });
        console.log(`🔀 [Vault] upgrade de tier: ${existing.tierId} → ${tierId} (${providerPubkey.substring(0, 8)}). Antiga devolvida no vencimento.`);
      } else {
        throw new Error(`Provedor já tem garantia ativa (status: ${existing.status})`);
      }
    }

    const adminPk = (process.env.ADMIN_PUBKEY || '').toLowerCase();
    let expiry = DEFAULT_EXPIRY_SECS;
    if (expirySecs && providerPubkey === adminPk) {
      expiry = Math.max(MIN_TEST_EXPIRY_SECS, Math.min(expirySecs, DEFAULT_EXPIRY_SECS));
    }

    const preimage = crypto.randomBytes(32).toString('hex');
    const paymentHash = crypto.createHash('sha256').update(Buffer.from(preimage, 'hex')).digest('hex');

    const sdk = await this._getSdk();
    const res = await sdk.receivePayment({
      paymentMethod: {
        type: 'bolt11Invoice',
        description: `Bro Garantia ${tierName || tierId}`,
        amountSats,
        expirySecs: expiry,
        // HODL DE VERDADE: SÓ o paymentHash. Se o preimage for passado aqui,
        // o SDK o REVELA sozinho quando o pagamento chega (auto-settle —
        // descoberto em produção 05/11: garantia da Carol caiu como
        // 'preimageShared'/completed em vez de ficar travada). O preimage
        // fica SÓ no nosso store criptografado; slash = claimHtlcPayment.
        paymentHash,
      },
    });

    const now = Math.floor(Date.now() / 1000);
    const record = {
      paymentHash,
      providerPubkey,
      tierId,
      tierName: tierName || tierId,
      amountSats,
      invoice: res.paymentRequest,
      status: 'awaiting_payment',
      expirySecs: expiry,
      createdAt: now,
      expiresAt: null, // preenchido quando travar (pagamento chega)
      lockedAt: null,
      preimageEnc: this._encryptPreimage(preimage),
      renewals: [],
      history: [{ at: now, event: 'invoice_created', expirySecs: expiry }],
    };
    this._records.set(paymentHash, record);
    this._saveState();
    console.log(`🔐 [Vault] Garantia criada: ${paymentHash.substring(0, 12)}… provedor=${providerPubkey.substring(0, 8)} ${amountSats} sats tier=${tierId}`);
    return { invoice: record.invoice, paymentHash, reused: false };
  }

  /**
   * Provedor pede liberação. PRÉ-ASSINATURA DA PLATAFORMA: se o watchtower
   * confirma ZERO ordens pendentes, libera na hora (sem fila da admin). Com
   * pendências ou sem dados confiáveis → fila manual (fail-safe a favor da
   * plataforma: na dúvida, um humano decide).
   */
  async requestRelease(providerPubkey) {
    const r = this.getActiveForProvider(providerPubkey);
    if (!r) throw new Error('Nenhuma garantia ativa encontrada');
    if (r.status !== 'locked') throw new Error(`Garantia não está travada (status: ${r.status})`);
    const now = Math.floor(Date.now() / 1000);

    let pending = null;
    try {
      pending = this._watchtower?.getPendingOrdersForProvider(providerPubkey) ?? null;
    } catch (_) { pending = null; }

    if (pending != null && pending.length === 0) {
      r.status = 'released';
      r.history.push({ at: now, event: 'release_auto_approved' });
      this._saveState();
      await this._push(r.providerPubkey, {
        title: '🔓 Garantia liberada automaticamente',
        body: `Sem ordens pendentes! Os ${r.amountSats} sats voltam pra sua carteira no vencimento do ciclo.`,
      }, { type: 'hodl_vault', subtype: 'released' });
      const adminPk = (process.env.ADMIN_PUBKEY || '').toLowerCase();
      if (adminPk) {
        await this._push(adminPk, {
          title: 'ℹ️ Liberação automática de garantia',
          body: `Provedor ${providerPubkey.substring(0, 8)} sem pendências — ${r.amountSats} sats liberados sem fila.`,
        }, { type: 'hodl_vault', subtype: 'admin_auto_release' });
      }
      console.log(`🔓 [Vault] Liberação AUTOMÁTICA: ${r.paymentHash.substring(0, 12)}… provedor=${providerPubkey.substring(0, 8)} sem pendências`);
      return this._publicRecord(r);
    }

    r.status = 'release_pending';
    r.history.push({ at: now, event: 'release_requested', pendingOrders: pending?.length ?? 'unknown' });
    this._saveState();
    const adminPk = (process.env.ADMIN_PUBKEY || '').toLowerCase();
    if (adminPk) {
      const pendInfo = pending == null
        ? 'pendências desconhecidas (watchtower sem dados)'
        : `${pending.length} ordem(ns) pendente(s): ${pending.map(o => o.substring(0, 8)).join(', ')}`;
      await this._push(adminPk, {
        title: '🔓 Pedido de liberação de garantia',
        body: `Provedor ${providerPubkey.substring(0, 8)} quer liberar ${r.amountSats} sats — ${pendInfo}. Revise no admin.`,
      }, { type: 'hodl_vault', subtype: 'admin_release_request' });
    }
    console.log(`🔓 [Vault] Liberação EM FILA: ${r.paymentHash.substring(0, 12)}… provedor=${providerPubkey.substring(0, 8)}`);
    return this._publicRecord(r);
  }

  /** Admin aprova a liberação. NÃO recolhe: os sats voltam no vencimento. */
  async adminApproveRelease(paymentHash) {
    const r = this._records.get(paymentHash);
    if (!r) throw new Error('Garantia não encontrada');
    if (r.status !== 'release_pending' && r.status !== 'locked') {
      throw new Error(`Status inválido pra liberação: ${r.status}`);
    }
    r.status = 'released';
    r.history.push({ at: Math.floor(Date.now() / 1000), event: 'release_approved' });
    this._saveState();
    await this._push(r.providerPubkey, {
      title: '🔓 Garantia liberada',
      body: `Sua garantia de ${r.amountSats} sats foi liberada. Os sats voltam pra sua carteira automaticamente até o vencimento.`,
    }, { type: 'hodl_vault', subtype: 'released' });
    console.log(`🔓 [Vault] Liberação APROVADA: ${paymentHash.substring(0, 12)}… (devolução no expiry)`);
    return this._publicRecord(r);
  }

  /** Admin manda AVISO de slash (mau comportamento) — sem recolher nada. */
  async slashNotify(paymentHash, reason) {
    const r = this._records.get(paymentHash);
    if (!r) throw new Error('Garantia não encontrada');
    r.history.push({ at: Math.floor(Date.now() / 1000), event: 'slash_warning', reason });
    this._saveState();
    await this._push(r.providerPubkey, {
      title: '⚠️ Aviso da plataforma sobre sua garantia',
      body: reason || 'Detectamos um comportamento que pode levar ao recolhimento da sua garantia. Verifique suas ordens e disputas.',
    }, { type: 'hodl_vault', subtype: 'slash_warning' });
    console.log(`⚠️ [Vault] Aviso de slash enviado: ${paymentHash.substring(0, 12)}… motivo=${reason || '-'}`);
    return this._publicRecord(r);
  }

  /** Admin RECOLHE a garantia (settle com preimage). Irreversível. */
  async slashCollect(paymentHash, reason) {
    const r = this._records.get(paymentHash);
    if (!r) throw new Error('Garantia não encontrada');
    if (r.status !== 'locked' && r.status !== 'release_pending') {
      throw new Error(`Só é possível recolher garantia travada (status: ${r.status})`);
    }
    const sdk = await this._getSdk();
    const preimage = this._decryptPreimage(r.preimageEnc);
    await sdk.claimHtlcPayment({ preimage });
    r.status = 'slashed';
    r.history.push({ at: Math.floor(Date.now() / 1000), event: 'slashed', reason });
    this._saveState();
    await this._push(r.providerPubkey, {
      title: '🚨 Garantia recolhida pela plataforma',
      body: `Sua garantia de ${r.amountSats} sats foi recolhida. Motivo: ${reason || 'prejuízo comprovado'}. Fale com o suporte.`,
    }, { type: 'hodl_vault', subtype: 'slashed' });
    console.log(`🚨 [Vault] SLASH executado: ${paymentHash.substring(0, 12)}… ${r.amountSats} sats recolhidos. Motivo: ${reason || '-'}`);
    return this._publicRecord(r);
  }

  /**
   * Admin: paga uma invoice bolt11 qualquer com a carteira do cofre
   * (devoluções de trial etc). Usa o SDK JÁ VIVO do serviço — a tool
   * externa _vault_pay.js morria ao subir um segundo SDK (e usava
   * paymentRequest type 'input', que quebrava o sendPayment).
   */
  async adminPayout(invoice) {
    if (typeof invoice !== 'string' || !invoice.toLowerCase().startsWith('lnbc')) {
      throw new Error('invoice inválida (só mainnet)');
    }
    const sdk = await this._getSdk();
    const prepare = await sdk.prepareSendPayment({
      paymentRequest: { type: 'bolt11Invoice', invoice },
    });
    const resp = await sdk.sendPayment({
      prepareResponse: prepare,
      options: { type: 'bolt11Invoice', preferSpark: true, completionTimeoutSecs: 60 },
    });
    console.log(`💸 [Vault] Payout: ${resp.payment.amount?.toString()} sats, status=${resp.payment.status}, id=${resp.payment.id}`);
    return {
      paymentId: resp.payment.id,
      status: String(resp.payment.status),
      amountSats: resp.payment.amount?.toString(),
      feeSats: resp.payment.fees?.toString(),
    };
  }

  /**
   * Renovação: se a garantia está travada e perto do vencimento (e NÃO foi
   * liberada), cria o próximo invoice HODL encadeado. O app paga e o ciclo
   * continua. Se foi liberada, devolve null — os sats voltam no expiry.
   */
  async createRenewalInvoice(providerPubkey) {
    const r = this.getActiveForProvider(providerPubkey);
    if (!r) return null;
    if (r.status !== 'locked') return null;
    const now = Math.floor(Date.now() / 1000);
    if (!r.expiresAt || (r.expiresAt - now) > RENEW_WINDOW_SECS) return null; // ainda longe

    const preimage = crypto.randomBytes(32).toString('hex');
    const paymentHash = crypto.createHash('sha256').update(Buffer.from(preimage, 'hex')).digest('hex');
    const sdk = await this._getSdk();
    const res = await sdk.receivePayment({
      paymentMethod: {
        type: 'bolt11Invoice',
        description: `Bro Garantia ${r.tierName} (renovação)`,
        amountSats: r.amountSats,
        expirySecs: r.expirySecs,
        // HODL: SÓ paymentHash (ver createLockInvoice — preimage no SDK = auto-settle)
        paymentHash,
      },
    });
    r.renewals.push({
      paymentHash,
      invoice: res.paymentRequest,
      createdAt: now,
      expiresAt: now + r.expirySecs,
      preimageEnc: this._encryptPreimage(preimage),
      paid: false,
    });
    r.history.push({ at: now, event: 'renewal_invoice_created' });
    this._saveState();
    console.log(`🔄 [Vault] Renovação criada pra ${paymentHash.substring(0, 12)}… (garantia ${r.paymentHash.substring(0, 12)}…)`);
    return { invoice: res.paymentRequest, paymentHash, amountSats: r.amountSats };
  }

  // ── Polling de status (HTLCs inbound) ─────────────────────────────────

  _startPolling() {
    if (this._pollTimer) return;
    this._pollTimer = setInterval(() => this._refreshStatuses().catch(() => {}), POLL_INTERVAL_MS);
    this._pollTimer.unref?.();
  }

  async _refreshStatuses() {
    if (!this._sdk) return;
    // Varre pagamentos inbound com HTLC pendente/devolvido.
    // ATENÇÃO: paymentDetailsFilter é ARRAY (objeto solto não casa nada —
    // bug real 05/11: garantia paga ficou eternamente 'awaiting_payment').
    const [pending, returned, settled] = await Promise.all([
      this._sdk.listPayments({
        typeFilter: ['receive'],
        paymentDetailsFilter: [{ type: 'lightning', htlcStatus: ['waitingForPreimage'] }],
        limit: 100,
      }).catch(() => ({ payments: [] })),
      this._sdk.listPayments({
        typeFilter: ['receive'],
        paymentDetailsFilter: [{ type: 'lightning', htlcStatus: ['returned'] }],
        limit: 100,
      }).catch(() => ({ payments: [] })),
      // preimageShared = pagamento COMPLETADO (normal: depois de um slash;
      // anômalo: preimage vazou pro SDK — caso do bug de 05/11)
      this._sdk.listPayments({
        typeFilter: ['receive'],
        paymentDetailsFilter: [{ type: 'lightning', htlcStatus: ['preimageShared'] }],
        limit: 100,
      }).catch(() => ({ payments: [] })),
    ]);

    const now = Math.floor(Date.now() / 1000);
    const seen = new Map(); // paymentHash → 'waiting' | 'returned' | 'settled'
    for (const p of pending.payments || []) {
      const h = p.details?.htlcDetails?.paymentHash;
      if (h) seen.set(h, 'waiting');
    }
    for (const p of returned.payments || []) {
      const h = p.details?.htlcDetails?.paymentHash;
      if (h) seen.set(h, 'returned');
    }
    for (const p of settled.payments || []) {
      const h = p.details?.htlcDetails?.paymentHash;
      if (h) seen.set(h, 'settled');
    }

    for (const r of this._records.values()) {
      // limpeza: invoice criado há >24h e nunca pago → abandonado
      if (r.status === 'awaiting_payment' && (now - r.createdAt) > 24 * 3600) {
        r.status = 'abandoned';
        r.history.push({ at: now, event: 'abandoned_unpaid_24h' });
        this._saveState();
        continue;
      }
      // garantia principal
      await this._applyObservedStatus(r, r.paymentHash, seen.get(r.paymentHash), now, false);
      // renovações encadeadas
      for (const ren of r.renewals || []) {
        if (!ren.paid && seen.get(ren.paymentHash) === 'waiting') {
          ren.paid = true;
          r.history.push({ at: now, event: 'renewal_paid', paymentHash: ren.paymentHash });
          // a renovação passa a ser a âncora da garantia
          r.expiresAt = ren.expiresAt;
          this._saveState();
          console.log(`🔄 [Vault] Renovação PAGA: garantia ${r.paymentHash.substring(0, 12)}… estendida até ${new Date(ren.expiresAt * 1000).toISOString()}`);
        }
      }
    }
  }

  async _applyObservedStatus(r, hash, observed, now, isRenewal) {
    if (r.status === 'awaiting_payment' && observed === 'waiting') {
      r.status = 'locked';
      r.lockedAt = now;
      r.expiresAt = now + r.expirySecs;
      r.history.push({ at: now, event: 'locked' });
      this._saveState();
      await this._push(r.providerPubkey, {
        title: '🔒 Garantia travada com sucesso',
        body: `Seu tier ${r.tierName} está ativo com ${r.amountSats} sats em garantia.`,
      }, { type: 'hodl_vault', subtype: 'locked' });
      console.log(`🔒 [Vault] Garantia TRAVADA: ${hash.substring(0, 12)}… ${r.amountSats} sats de ${r.providerPubkey.substring(0, 8)}`);
    } else if (r.status === 'awaiting_payment' && observed === 'settled') {
      // ANOMALIA: completou sem travar (preimage conhecido pelo SDK — não
      // deveria mais acontecer; cobre registros legados do bug de 05/11).
      r.status = 'settled';
      r.history.push({ at: now, event: 'settled_without_lock_ANOMALY' });
      this._saveState();
      console.error(`⚠️ [Vault] garantia SETTLED sem passar por locked: ${hash.substring(0, 12)}… — verificar`);
    } else if ((r.status === 'locked' || r.status === 'released') && observed === 'returned') {
      const wasReleased = r.status === 'released';
      r.status = wasReleased ? 'returned' : 'expired_unreleased';
      r.history.push({ at: now, event: wasReleased ? 'returned_after_release' : 'EXPIRED_WITHOUT_RELEASE' });
      this._saveState();
      if (wasReleased) {
        await this._push(r.providerPubkey, {
          title: '✅ Garantia devolvida',
          body: `Os ${r.amountSats} sats da sua garantia voltaram pra sua carteira.`,
        }, { type: 'hodl_vault', subtype: 'returned' });
        console.log(`✅ [Vault] Garantia devolvida: ${hash.substring(0, 12)}…`);
      } else {
        // GARANTIA EXPIROU SEM RENOVAÇÃO — sats voltaram pro provedor e o
        // tier ficou sem lastro. Alertar admin: provedor operando sem garantia.
        console.error(`🚨 [Vault] Garantia EXPIROU sem renovação/liberação: ${hash.substring(0, 12)}… provedor=${r.providerPubkey.substring(0, 8)}`);
        const adminPk = (process.env.ADMIN_PUBKEY || '').toLowerCase();
        if (adminPk) {
          await this._push(adminPk, {
            title: '🚨 Garantia expirou sem renovação',
            body: `Provedor ${r.providerPubkey.substring(0, 8)} deixou a garantia de ${r.amountSats} sats expirar (tier ${r.tierName}). Verifique se ele ainda aceita ordens.`,
          }, { type: 'hodl_vault', subtype: 'admin_expired' });
        }
      }
    }
  }

  async _push(pubkey, notification, data) {
    try {
      await pushService.sendPush(pubkey, data, notification);
    } catch (e) {
      console.error(`⚠️ [Vault] push falhou: ${e.message}`);
    }
  }

  stop() {
    if (this._pollTimer) clearInterval(this._pollTimer);
    this._pollTimer = null;
  }
}

module.exports = new HodlVaultService();
