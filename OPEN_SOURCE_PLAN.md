# Plano de Ação — Open-Source Readiness

> **Criado:** 2026-02-18  
> **Versão estável:** v1.0.111-stable (tag)  
> **Build testers:** v1.0.112+182  
> **Status:** Fase 2 concluída

---

## Fase 1: Blindagem Imediata ⚡
*PRÉ-REQUISITO ABSOLUTO — sem isso, o repo NÃO pode ser aberto*

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 1.1 | Externalizar Breez API key via `--dart-define` | Pequeno | ✅ |
| 1.2 | Externalizar `platformLightningAddress` | Pequeno | ✅ |
| 1.3 | Trocar `defaultBackendUrl` para produção ou var ambiente | Pequeno | ✅ |
| 1.4 | Sanitizar docs .md (IPs internos, emails, detalhes operacionais) | Pequeno | ✅ |
| 1.5 | Remover `check_relay.js`/`check_relay2.js` | Trivial | ✅ |
| 1.6 | Criar `.env.example` para o Flutter app | Trivial | ✅ |

**Arquivos afetados:** `lib/config.dart`, `lib/config/breez_config.dart`, docs `.md`, raiz

---

## Fase 2: Verificação Criptográfica 🔐
*Impede fraude via relay malicioso*

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 2.1 | Adicionar `Event.verify()` em todo evento recebido no `NostrOrderService` | Pequeno | ✅ |
| 2.2 | Adicionar `Event.verify()` no `ChatService._handleIncomingEvent()` | Pequeno | ✅ |
| 2.3 | Validar `event.pubkey` vs papel esperado (providerId ou userPubkey) | Médio | ✅ |

**Arquivos afetados:** `lib/services/nostr_order_service.dart`, `lib/services/chat_service.dart`

---

## Fase 3: Criptografia de Dados das Ordens 🛡️
*Protege PII (PIX keys = CPF/telefone) e comprovantes nos relays*

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 3.1 | Encriptar `billCode` no kind 30078 usando NIP-44 | Médio | ⬜ |
| 3.2 | Encriptar `proofImageBase64` no kind 30081 | Médio | ⬜ |
| 3.3 | Descriptografar nos pontos de leitura | Médio | ⬜ |
| 3.4 | Retrocompatibilidade: plaintext para ordens antigas | Pequeno | ⬜ |

**Arquivos afetados:** `lib/services/nostr_order_service.dart`, `lib/services/nip44_service.dart`

---

## Fase 4: Autenticação do Backend 🔒
*Impede manipulação direta da API*

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 4.1 | Adicionar `nostr-tools` ao backend | Trivial | ⬜ |
| 4.2 | Criar middleware `verifyNip98Auth.js` | Médio | ⬜ |
| 4.3 | Aplicar middleware em todas as rotas | Pequeno | ⬜ |
| 4.4 | Usar pubkey verificado como userId (não aceitar do body) | Pequeno | ⬜ |
| 4.5 | Adicionar rate limiting (`express-rate-limit`) | Pequeno | ⬜ |
| 4.6 | Restringir CORS | Pequeno | ⬜ |

**Arquivos afetados:** `backend/server.js`, `backend/routes/*.js`, `backend/package.json`

---

## Fase 5: Hardening de Storage Local 💾
*Protege chaves no dispositivo*

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 5.1 | Remover backup de seeds em SharedPreferences | Médio | ⬜ |
| 5.2 | Consolidar StorageService + SecureStorageService | Médio | ⬜ |
| 5.3 | Mover cache de chat para storage encriptado | Pequeno | ⬜ |
| 5.4 | Migração automática: SharedPrefs → SecureStorage | Médio | ⬜ |

**Arquivos afetados:** `lib/services/storage_service.dart`, `lib/services/secure_storage_service.dart`

---

## Fase 6: Chat e Melhorias Finais 🔧

| # | Tarefa | Esforço | Status |
|---|--------|---------|--------|
| 6.1 | Integrar NIP-44 ao ChatService | Pequeno | ⬜ |
| 6.2 | Proteção contra replay (rastrear event IDs) | Pequeno | ⬜ |
| 6.3 | Implementar payment_validation_service.dart | Médio | ⬜ |
| 6.4 | Backend: migrar de in-memory para SQLite/PostgreSQL | Grande | ⬜ |

---

## Cronograma Sugerido

```
Semana 1: Fase 1 (blindagem) + Fase 2 (verificação de assinaturas)
Semana 2: Fase 3 (criptografia de ordens)
Semana 3: Fase 4 (auth backend)
Semana 4: Fase 5 (storage) + Fase 6 (melhorias)
Semana 5: Testes integrados + revisão final + abertura do repo
```

## Vulnerabilidades Conhecidas

Veja o documento interno de auditoria de segurança para detalhes.
Este plano endereça todas as vulnerabilidades identificadas nas fases acima.
