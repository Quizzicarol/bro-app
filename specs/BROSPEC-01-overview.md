# BROSPEC-01: Visão Geral do Protocolo Bro

`draft` `mandatory`

## Resumo

O Protocolo Bro é um protocolo aberto para troca P2P de Bitcoin (via Lightning Network) por pagamentos fiduciários (PIX, Boleto, TED), construído sobre o protocolo Nostr.

## Motivação

Atualmente, converter Bitcoin para moeda fiduciária (e vice-versa) requer intermediários centralizados (exchanges, corretoras) que:
- Exigem KYC e verificação de identidade
- Cobram taxas elevadas
- Podem censurar transações
- Representam pontos únicos de falha

O Protocolo Bro permite que qualquer pessoa:
- Pague contas (PIX, Boletos) usando Bitcoin
- Ofereça serviço de pagamento de contas (como Provedor/Bro)
- Faça trocas P2P sem intermediários centralizados

## Arquitetura

```
┌─────────────┐                 ┌─────────────┐
│   USUÁRIO   │                 │   PROVEDOR  │
│  (Cliente)  │                 │    (Bro)    │
└──────┬──────┘                 └──────┬──────┘
       │                               │
       │  1. Publica Ordem (kind 30078)│
       ├──────────────────────────────►│
       │                               │
       │  2. Aceita Ordem (kind 30079) │
       │◄──────────────────────────────┤
       │                               │
       │  3. Paga Invoice Lightning    │
       ├──────────────────────────────►│
       │                               │
       │         4. Provedor paga      │
       │         PIX/Boleto no mundo   │
       │         real                  │
       │                               │
       │  5. Envia Comprovante (30081) │
       │◄──────────────────────────────┤
       │                               │
       │  6. Confirma Recebimento      │
       ├──────────────────────────────►│
       │                               │
       ▼                               ▼
┌──────────────────────────────────────────┐
│           RELAYS NOSTR                    │
│  (Comunicação descentralizada)            │
└──────────────────────────────────────────┘
```

## Componentes

### 1. Clientes (Usuários)
Aplicações que permitem usuários criarem ordens de pagamento.

### 2. Provedores (Bros)
Agentes que aceitam ordens e executam pagamentos fiduciários em troca de Bitcoin.

### 3. Relays Nostr
Infraestrutura de comunicação descentralizada que transmite eventos entre participantes.

### 4. Lightning Network
Rede de pagamentos Bitcoin usada para transferir valor de forma instantânea.

## Event Kinds

O Protocolo Bro utiliza os seguintes kinds reservados:

| Kind | Descrição | Spec |
|------|-----------|------|
| `30078` | Ordem de Pagamento | BROSPEC-02 |
| `30079` | Aceitação de Ordem | BROSPEC-02 |
| `30080` | Atualização de Status | BROSPEC-02 |
| `30081` | Conclusão com Comprovante | BROSPEC-02 |
| `30082` | Perfil de Provedor | BROSPEC-05 |
| `4` | DM Criptografada (NIP-04) | Chat privado |

## Princípios de Design

### 1. Descentralização
- Sem servidor central obrigatório
- Qualquer relay Nostr pode transmitir eventos Bro
- Provedores podem operar independentemente

### 2. Privacidade
- Dados sensíveis (códigos PIX/Boleto) são criptografados
- Comunicação via DMs criptografadas (NIP-04/NIP-44)
- Sem registro ou KYC obrigatório

### 3. Interoperabilidade
- Baseado em padrões abertos (Nostr, Lightning)
- Qualquer cliente pode implementar o protocolo
- Provedores de diferentes clientes são compatíveis

### 4. Simplicidade
- Fluxo direto: ordem → aceite → pagamento → confirmação
- Poucos event kinds necessários
- Fácil de implementar e auditar

## Fluxo Básico

1. **Usuário cria ordem** (kind 30078)
   - Especifica tipo (PIX/Boleto), valor, código de pagamento
   - Publica nos relays

2. **Provedor vê ordem** 
   - Filtra ordens por tags `#t: bro-order`
   - Avalia se quer aceitar

3. **Provedor aceita** (kind 30079)
   - Publica evento de aceitação
   - Usuário vê via tag `#p` (menção)

4. **Usuário paga Lightning**
   - Paga invoice do provedor
   - Valor: BRL convertido + taxa do provedor

5. **Provedor executa pagamento**
   - Paga PIX/Boleto no sistema bancário
   - Obtém comprovante

6. **Provedor envia comprovante** (kind 30081)
   - Publica evento com prova de pagamento
   - Usuário confirma recebimento

## Specs Relacionadas

- **BROSPEC-02**: Eventos e Mensagens
- **BROSPEC-03**: Fluxo de Ordens
- **BROSPEC-04**: Sistema de Escrow
- **BROSPEC-05**: Sistema de Reputação
- **BROSPEC-06**: Descoberta de Provedores

## NIPs Utilizadas

O Protocolo Bro depende das seguintes NIPs do Nostr:

- **NIP-01**: Protocolo básico e evento
- **NIP-04**: Mensagens diretas criptografadas
- **NIP-10**: Marcação de eventos (reply/root)
- **NIP-19**: Entidades codificadas (npub, nsec)
- **NIP-33**: Eventos Parametrized Replaceable (kinds 30xxx)

## Compatibilidade

- **Clientes Nostr**: Eventos Bro aparecem como eventos desconhecidos em clientes normais (não interferem)
- **Relays**: Qualquer relay NIP-01 compatível funciona
- **Lightning**: Qualquer wallet Lightning compatível com BOLT-11

---

*Versão: 0.1-draft*
*Data: Janeiro 2026*
