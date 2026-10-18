/**
 * paymentVerifier.js — Structural validation for PIX (BR Code/EMV) and Boleto.
 *
 * NO external API calls. Pure structural / checksum verification:
 *  - PIX BR Code: parses TLV (EMV QR) and validates CRC16-CCITT checksum.
 *  - PIX E2E ID: structural shape (E + ISPB + YYYYMMDDHHmm + 11 chars).
 *  - Boleto linha digitável: mod-10 (positions 1-2-3-4-5) + mod-11 DV.
 *
 * Used by disputeAgentService to add `payment_findings` to disputes,
 * boosting confidence when codes are well-formed and flagging when not.
 *
 * v557 Phase: B4 from audit.
 */

// ---- PIX BR Code (EMV QR) ----------------------------------------------

/**
 * Parses an EMV TLV payload into a Map of id -> value.
 */
function _parseEmvTlv(payload) {
  const map = new Map();
  let i = 0;
  while (i < payload.length - 4) {
    const id = payload.substring(i, i + 2);
    const len = parseInt(payload.substring(i + 2, i + 4), 10);
    if (!Number.isFinite(len)) return map;
    const val = payload.substring(i + 4, i + 4 + len);
    map.set(id, val);
    i += 4 + len;
  }
  return map;
}

/**
 * CRC16-CCITT (poly 0x1021, init 0xFFFF) over ASCII bytes.
 * Spec: BCB Manual de Padrões PIX.
 */
function _crc16Ccitt(str) {
  let crc = 0xFFFF;
  for (let i = 0; i < str.length; i++) {
    crc ^= str.charCodeAt(i) << 8;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/**
 * Validates a PIX BR Code (copy-paste). Returns {valid, findings, parsed}.
 *
 * Findings cover:
 *  - empty / wrong format
 *  - CRC mismatch
 *  - amount mismatch (id 54) vs `expectedAmountBrl` if provided
 */
function verifyPixBrCode(brCode, opts = {}) {
  const findings = [];
  const result = { valid: false, findings, parsed: null };
  if (!brCode || typeof brCode !== 'string') {
    findings.push({ id: 'pix_empty', severity: 'high', detail: 'BR Code vazio' });
    return result;
  }
  const trimmed = brCode.trim();
  if (trimmed.length < 30 || trimmed.length > 1024) {
    findings.push({ id: 'pix_length', severity: 'medium', detail: `Tamanho fora da faixa: ${trimmed.length}` });
    return result;
  }
  // Last 8 chars: 6304XXXX (CRC tag + 4-digit hex)
  const crcTagPos = trimmed.length - 8;
  if (trimmed.substring(crcTagPos, crcTagPos + 4) !== '6304') {
    findings.push({ id: 'pix_no_crc_tag', severity: 'high', detail: 'Tag 6304 não encontrada nos últimos 8 chars' });
    return result;
  }
  const expectedCrc = trimmed.substring(crcTagPos + 4).toUpperCase();
  const actualCrc = _crc16Ccitt(trimmed.substring(0, crcTagPos + 4))
    .toString(16).toUpperCase().padStart(4, '0');
  if (expectedCrc !== actualCrc) {
    findings.push({ id: 'pix_crc_mismatch', severity: 'high', detail: `CRC esperado=${expectedCrc} calculado=${actualCrc}` });
    return result;
  }

  const tlv = _parseEmvTlv(trimmed.substring(0, crcTagPos));
  result.parsed = {
    payloadFormat: tlv.get('00') || null,
    merchantAccount: tlv.get('26') || null,
    merchantCategory: tlv.get('52') || null,
    txCurrency: tlv.get('53') || null,
    amount: tlv.get('54') || null,
    countryCode: tlv.get('58') || null,
    merchantName: tlv.get('59') || null,
    merchantCity: tlv.get('60') || null,
    additional: tlv.get('62') || null,
  };

  // v668: extrai a chave Pix de dentro da tag 26 (sub-TLV EMV: 00=GUI, 01=chave)
  const mai = result.parsed.merchantAccount;
  if (mai) {
    const sub = _parseEmvTlv(mai);
    result.parsed.pixKey = sub.get('01') || null;
    result.parsed.pixGui = sub.get('00') || null;
  }

  if (opts.expectedAmountBrl != null && result.parsed.amount) {
    const codeAmt = parseFloat(result.parsed.amount);
    const expected = parseFloat(opts.expectedAmountBrl);
    if (Number.isFinite(codeAmt) && Number.isFinite(expected) &&
        Math.abs(codeAmt - expected) > 0.01) {
      findings.push({
        id: 'pix_amount_mismatch',
        severity: 'high',
        detail: `Valor do BR Code R$ ${codeAmt} != ordem R$ ${expected}`,
      });
    }
  }

  // v668: a chave Pix embutida no QR TEM que ser a chave da ordem — QR
  // apontando pra outra chave = pagamento foi pra outro destino (fraude/erro).
  if (opts.expectedPixKey && result.parsed.pixKey) {
    const a = String(result.parsed.pixKey).trim().toLowerCase();
    const b = String(opts.expectedPixKey).trim().toLowerCase();
    if (a && b && a !== b) {
      findings.push({
        id: 'pix_key_mismatch',
        severity: 'high',
        detail: `Chave do QR (${a}) != chave da ordem (${b})`,
      });
    }
  }

  result.valid = !findings.some(f => f.severity === 'high');
  return result;
}

// ---- PIX E2E (End-to-end identifier) -----------------------------------

// Spec: "E" + 8-digit ISPB + YYYYMMDDHHmm (12 digits) + 11 alphanumerics = 32 chars
const E2E_REGEX = /^E\d{8}\d{12}[A-Za-z0-9]{11}$/;

function verifyPixE2E(e2e, opts = {}) {
  const findings = [];
  if (!e2e || typeof e2e !== 'string') {
    findings.push({ id: 'e2e_empty', severity: 'high', detail: 'E2E vazio' });
    return { valid: false, findings };
  }
  const v = e2e.trim();
  if (!E2E_REGEX.test(v)) {
    findings.push({ id: 'e2e_format', severity: 'high', detail: 'Formato E2E inválido (esperado: E + 8 ISPB + 12 datetime + 11 alfanum)' });
    return { valid: false, findings };
  }

  // Parse datetime (positions 9..21 are YYYYMMDDHHmm)
  const datePart = v.substring(9, 21);
  const yyyy = parseInt(datePart.substring(0, 4), 10);
  const mm   = parseInt(datePart.substring(4, 6), 10);
  const dd   = parseInt(datePart.substring(6, 8), 10);
  const hh   = parseInt(datePart.substring(8, 10), 10);
  const mi   = parseInt(datePart.substring(10, 12), 10);
  if (yyyy < 2020 || yyyy > 2099 || mm < 1 || mm > 12 || dd < 1 || dd > 31 || hh > 23 || mi > 59) {
    findings.push({ id: 'e2e_datetime', severity: 'high', detail: `Datetime inválido no E2E: ${datePart}` });
    return { valid: false, findings };
  }

  if (opts.orderCreatedAt) {
    try {
      const e2eDt = Date.UTC(yyyy, mm - 1, dd, hh, mi);
      const orderDt = new Date(opts.orderCreatedAt).getTime();
      const diffH = Math.abs(orderDt - e2eDt) / (1000 * 60 * 60);
      if (diffH > 48) {
        findings.push({
          id: 'e2e_datetime_far_from_order',
          severity: 'medium',
          detail: `E2E datado a ${diffH.toFixed(1)}h da criação da ordem`,
        });
      }
    } catch (_) { /* ignore */ }
  }

  // v668: E2E datado ANTES da ordem existir = impossível (o pagador só
  // conhece o destino depois do aceite). E2E no futuro = forjado.
  try {
    const e2eMs = Date.UTC(yyyy, mm - 1, dd, hh, mi);
    const SKEW_MS = 15 * 60 * 1000; // tolerância p/ relógio dos PSPs
    if (opts.notBeforeMs && e2eMs < opts.notBeforeMs - SKEW_MS) {
      findings.push({
        id: 'e2e_before_order',
        severity: 'high',
        detail: 'E2E datado ANTES da criação da ordem — pagamento impossível/forjado',
      });
    }
    if (e2eMs > Date.now() + SKEW_MS) {
      findings.push({
        id: 'e2e_future',
        severity: 'high',
        detail: 'E2E datado no FUTURO — forjado',
      });
    }
  } catch (_) { /* ignore */ }

  return { valid: findings.every(f => f.severity !== 'high'), findings, ispb: v.substring(1, 9) };
}

// ---- Boleto linha digitável (47 dígitos) -------------------------------

function _mod10(numStr) {
  // Mod 10 com pesos 2,1 (boleto bancário)
  let sum = 0;
  let weight = 2;
  for (let i = numStr.length - 1; i >= 0; i--) {
    let v = parseInt(numStr[i], 10) * weight;
    if (v > 9) v = Math.floor(v / 10) + (v % 10);
    sum += v;
    weight = weight === 2 ? 1 : 2;
  }
  const dv = (10 - (sum % 10)) % 10;
  return dv;
}

function _mod11(numStr) {
  let sum = 0;
  let weight = 2;
  for (let i = numStr.length - 1; i >= 0; i--) {
    sum += parseInt(numStr[i], 10) * weight;
    weight = weight === 9 ? 2 : weight + 1;
  }
  const rem = sum % 11;
  const dv = 11 - rem;
  if (dv === 0 || dv === 10 || dv === 11) return 1;
  return dv;
}

/**
 * Validates Boleto bancário linha digitável (47 dígitos).
 * Format: 5+5DV  10+10DV  10+10DV  1DV  14factor+amount
 *         field1   field2    field3   gen  field4
 */
function verifyBoletoLinhaDigitavel(linha, opts = {}) {
  const findings = [];
  if (!linha || typeof linha !== 'string') {
    findings.push({ id: 'boleto_empty', severity: 'high', detail: 'Linha digitável vazia' });
    return { valid: false, findings };
  }
  const digits = linha.replace(/\D/g, '');
  if (digits.length !== 47) {
    findings.push({ id: 'boleto_length', severity: 'high', detail: `Esperado 47 dígitos, recebido ${digits.length}` });
    return { valid: false, findings };
  }

  // Field 1: 9 numeric + 1 DV (mod10) at position 9
  const f1 = digits.substring(0, 9);
  const f1dv = parseInt(digits.charAt(9), 10);
  if (_mod10(f1) !== f1dv) {
    findings.push({ id: 'boleto_field1_dv', severity: 'high', detail: `DV1 esperado ${_mod10(f1)} recebido ${f1dv}` });
  }
  // Field 2: 10 + 1DV
  const f2 = digits.substring(10, 20);
  const f2dv = parseInt(digits.charAt(20), 10);
  if (_mod10(f2) !== f2dv) {
    findings.push({ id: 'boleto_field2_dv', severity: 'high', detail: `DV2 esperado ${_mod10(f2)} recebido ${f2dv}` });
  }
  // Field 3: 10 + 1DV
  const f3 = digits.substring(21, 31);
  const f3dv = parseInt(digits.charAt(31), 10);
  if (_mod10(f3) !== f3dv) {
    findings.push({ id: 'boleto_field3_dv', severity: 'high', detail: `DV3 esperado ${_mod10(f3)} recebido ${f3dv}` });
  }
  // General DV (mod11) at position 32. Re-build código de barras (44 digits) and validate.
  const generalDv = parseInt(digits.charAt(32), 10);
  // barcode = field1(0..8) + field2(10..19) + field3(21..30) + DV + field4(33..46)
  const barcode = digits.substring(0, 4) + digits.charAt(32) /*DV pos 4*/ +
                  digits.substring(33, 47) /*factor+amount, 14*/ +
                  digits.substring(4, 9) + digits.substring(10, 20) + digits.substring(21, 31);
  // For DV check: use 43 digits without the DV
  const barcodeNoDv = barcode.substring(0, 4) + barcode.substring(5);
  const expectedDv = _mod11(barcodeNoDv);
  if (expectedDv !== generalDv) {
    findings.push({ id: 'boleto_general_dv', severity: 'high', detail: `DV geral esperado ${expectedDv} recebido ${generalDv}` });
  }

  // Amount (last 10 digits of field 4)
  const amountStr = digits.substring(37, 47);
  const amount = parseInt(amountStr, 10) / 100;
  if (opts.expectedAmountBrl != null && amount > 0) {
    const expected = parseFloat(opts.expectedAmountBrl);
    if (Number.isFinite(expected) && Math.abs(amount - expected) > 0.01) {
      findings.push({
        id: 'boleto_amount_mismatch',
        severity: 'high',
        detail: `Boleto R$ ${amount.toFixed(2)} != ordem R$ ${expected.toFixed(2)}`,
      });
    }
  }

  const hasHighSeverity = findings.some(f => f.severity === 'high');
  return {
    valid: !hasHighSeverity,
    findings,
    parsed: { amount, vencimentoFactor: parseInt(digits.substring(33, 37), 10) || 0 },
  };
}

// ---- Auto-detect & dispatch --------------------------------------------

// v615: EMVCo currency tag (53) numeric codes for the countries Bro supports.
// PIX/BRL (986) keeps its dedicated verifier above (verifyPixBrCode) untouched;
// the others reuse the same TLV+CRC16 structure (CoDi/MX, PromptPay/TH,
// Transferencias 3.0/AR, Bre-B/CO all follow the EMVCo QR spec).
const EMVCO_CURRENCY_NAMES = {
  '986': 'BRL',
  '484': 'MXN',
  '764': 'THB',
  '032': 'ARS',
  '170': 'COP',
  '356': 'INR',
  '840': 'USD',
  '978': 'EUR',
};

/**
 * Generic EMVCo QR verifier (non-PIX). Validates the same TLV structure and
 * CRC16-CCITT checksum used by PIX, but does NOT assume BRL — it reads the
 * currency (tag 53) and country (tag 58) and compares the amount (tag 54)
 * against `opts.expectedAmount` in the order's own currency.
 *
 * Returns {valid, findings, parsed, currency, country}.
 */
function verifyEmvcoQr(code, opts = {}) {
  const findings = [];
  const result = { valid: false, findings, parsed: null, currency: null, country: null };
  if (!code || typeof code !== 'string') {
    findings.push({ id: 'emvco_empty', severity: 'high', detail: 'QR vazio' });
    return result;
  }
  const trimmed = code.trim();
  if (trimmed.length < 20 || trimmed.length > 1024) {
    findings.push({ id: 'emvco_length', severity: 'medium', detail: `Tamanho fora da faixa: ${trimmed.length}` });
    return result;
  }
  const crcTagPos = trimmed.length - 8;
  if (trimmed.substring(crcTagPos, crcTagPos + 4) !== '6304') {
    findings.push({ id: 'emvco_no_crc_tag', severity: 'high', detail: 'Tag 6304 não encontrada nos últimos 8 chars' });
    return result;
  }
  const expectedCrc = trimmed.substring(crcTagPos + 4).toUpperCase();
  const actualCrc = _crc16Ccitt(trimmed.substring(0, crcTagPos + 4))
    .toString(16).toUpperCase().padStart(4, '0');
  if (expectedCrc !== actualCrc) {
    findings.push({ id: 'emvco_crc_mismatch', severity: 'high', detail: `CRC esperado=${expectedCrc} calculado=${actualCrc}` });
    return result;
  }

  const tlv = _parseEmvTlv(trimmed.substring(0, crcTagPos));
  const currencyNumeric = tlv.get('53') || null;
  const countryCode = tlv.get('58') || null;
  result.parsed = {
    payloadFormat: tlv.get('00') || null,
    merchantAccount: tlv.get('26') || tlv.get('27') || tlv.get('28') || null,
    merchantCategory: tlv.get('52') || null,
    txCurrency: currencyNumeric,
    amount: tlv.get('54') || null,
    countryCode,
    merchantName: tlv.get('59') || null,
    merchantCity: tlv.get('60') || null,
    additional: tlv.get('62') || null,
  };
  result.country = countryCode;
  result.currency = currencyNumeric ? (EMVCO_CURRENCY_NAMES[currencyNumeric] || currencyNumeric) : null;

  // Optional: expected currency check (numeric or ISO alpha)
  if (opts.expectedCurrency && currencyNumeric) {
    const expected = String(opts.expectedCurrency).toUpperCase();
    const actualAlpha = EMVCO_CURRENCY_NAMES[currencyNumeric] || currencyNumeric;
    if (expected !== currencyNumeric && expected !== actualAlpha) {
      findings.push({
        id: 'emvco_currency_mismatch',
        severity: 'high',
        detail: `Moeda do QR (${actualAlpha}/${currencyNumeric}) != esperada (${expected})`,
      });
    }
  }

  // Optional: amount check in the QR's own currency
  if (opts.expectedAmount != null && result.parsed.amount) {
    const codeAmt = parseFloat(result.parsed.amount);
    const expected = parseFloat(opts.expectedAmount);
    if (Number.isFinite(codeAmt) && Number.isFinite(expected) &&
        Math.abs(codeAmt - expected) > 0.01) {
      findings.push({
        id: 'emvco_amount_mismatch',
        severity: 'high',
        detail: `Valor do QR ${codeAmt} != ordem ${expected}`,
      });
    }
  }

  result.valid = !findings.some(f => f.severity === 'high');
  return result;
}

/** Lê apenas a tag 53 (moeda) de um payload EMVCo, sem validar CRC. */
function _peekEmvcoCurrency(trimmed) {
  try {
    const crcTagPos = trimmed.length - 8;
    const body = crcTagPos > 0 && trimmed.substring(crcTagPos, crcTagPos + 4) === '6304'
      ? trimmed.substring(0, crcTagPos)
      : trimmed;
    return _parseEmvTlv(body).get('53') || null;
  } catch (_) {
    return null;
  }
}

function verifyAny(code, opts = {}) {
  if (!code) return { type: 'unknown', valid: false, findings: [{ id: 'empty', severity: 'high', detail: 'Sem código' }] };
  const trimmed = String(code).trim();
  // E2E: starts with E and is 32 chars
  if (E2E_REGEX.test(trimmed)) {
    return { type: 'pix_e2e', ...verifyPixE2E(trimmed, opts) };
  }
  // EMVCo QR: starts with 000201 (payload format indicator).
  // BRL (986) -> dedicated PIX verifier (unchanged). Outras moedas -> EMVCo genérico.
  if (trimmed.startsWith('000201')) {
    const cur = _peekEmvcoCurrency(trimmed);
    if (cur && cur !== '986') {
      return { type: 'emvco_qr', ...verifyEmvcoQr(trimmed, opts) };
    }
    return { type: 'pix_brcode', ...verifyPixBrCode(trimmed, opts) };
  }
  // Boleto: 47 digits
  if (/^\d[\d\s.]*$/.test(trimmed) && trimmed.replace(/\D/g, '').length === 47) {
    return { type: 'boleto', ...verifyBoletoLinhaDigitavel(trimmed, opts) };
  }
  return { type: 'unknown', valid: false, findings: [{ id: 'unknown_format', severity: 'medium', detail: 'Formato não reconhecido' }] };
}

module.exports = {
  verifyPixBrCode,
  verifyPixE2E,
  verifyBoletoLinhaDigitavel,
  verifyEmvcoQr,
  verifyAny,
};
