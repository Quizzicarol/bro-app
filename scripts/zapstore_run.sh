#!/usr/bin/env bash
# Runs the zsp (Zapstore Go publisher) publish non-interactively.
# Called from zapstore_publish.ps1 via WSL. SIGN_WITH (nsec) arrives via WSLENV.
#
# Why this is more than a plain `zsp publish`:
#   nostr.download re-encodes uploaded images and DEDUPLICATES them server-wide.
#   When zsp tries to upload Bro's icon, the server already has the same image
#   (under a different, normalised hash) and returns HTTP 409 -> zsp aborts.
#
#   Fix (verified against zsp v0.4.10 source, internal/workflow/upload.go):
#     - If `icon:` in the config is a URL whose prefix == the Blossom server,
#       zsp uses it DIRECTLY (isBlossomURL shortcut) and never uploads -> no 409.
#     - The APK (sha256 b4e2b78f...) is already on nostr.download; zsp HEAD-checks
#       and skips re-upload.
#   The icon's real stored hash on nostr.download was discovered via the 409
#   `x-identical-media` header and is stable (content-addressed). We pin it below
#   and HEAD-verify it; if that ever fails we re-discover it dynamically using a
#   signed Blossom auth event (SIGN_WITH).
set -uo pipefail

PROJ=/mnt/c/Users/produ/Documents/GitHub/bro_app
ZSP="$HOME/bin/zsp"
NAK="$HOME/bin/nak"
APK="$HOME/bro-arm64.apk"
ICON="$HOME/bro_icon.png"
BLOSSOM="https://nostr.download"
APK_URL="https://github.com/Brostr/bro/releases/download/v1.0.133%2B619/bro-v1.0.133%2B619-arm64-v8a.apk"
# Known good icon hash on nostr.download (the normalised/stored form of Bro's icon).
KNOWN_ICON_HASH="e24b5558a311db65252613cdeabe51b8a30957be989685a6db948a1c6fd8717b"
export BLOSSOM_URL="$BLOSSOM"

cd "$PROJ" || exit 2

if [ -z "${SIGN_WITH:-}" ]; then
  echo "ERRO: SIGN_WITH ausente (a chave nao chegou via WSLENV)."
  exit 9
fi

# ---------------------------------------------------------------------------
# 0) Conferir que a chave assinante e a DONA da listagem app.bro.mobile.
#    Apenas ab6dc1fc... pode atualizar; qualquer outra e recusada pelo relay.
#    A chave nunca vai para argv: o nak le de stdin (printf e builtin).
# ---------------------------------------------------------------------------
EXPECTED_PUB="ab6dc1fcd5659b406d3e0512e05e8afde3b9bfc776e0a9657f57eae9ef069a2e"
SIGNER_PUB=$(printf '%s' "$SIGN_WITH" | "$NAK" key public 2>/dev/null | tr -d '[:space:]')
if [ -z "$SIGNER_PUB" ]; then
  echo "ERRO: nao consegui derivar a pubkey da chave (formato invalido?)."
  exit 10
fi
if [ "$SIGNER_PUB" != "$EXPECTED_PUB" ]; then
  echo "ERRO: a chave assinante NAO e a dona da listagem app.bro.mobile."
  echo "  esperado (dono): $EXPECTED_PUB"
  echo "  derivado:        $SIGNER_PUB"
  echo "  -> o relay recusaria com 'another pubkey ...'. Abortando."
  exit 11
fi
echo "==> chave OK: assinante e a dona da listagem (ab6dc1fc...)."

# ---------------------------------------------------------------------------
# 1) Determinar a URL do icone hospedado no nostr.download.
#    Caminho rapido: usar o hash conhecido (se o HEAD responder 200).
# ---------------------------------------------------------------------------
ICONHASH=""
if curl -sfI "$BLOSSOM/$KNOWN_ICON_HASH" >/dev/null 2>&1; then
  ICONHASH="$KNOWN_ICON_HASH"
  echo "==> icone conhecido acessivel: $BLOSSOM/$ICONHASH"
else
  echo "==> hash conhecido nao resolveu; redescobrindo dinamicamente..."
  # Extrair o icone processado do APK, se preciso.
  if [ ! -s "$ICON" ]; then
    [ -s "$APK" ] || curl -fL -o "$APK" "$APK_URL" 2>/dev/null || true
    "$ZSP" publish -q --offline "$APK" >/dev/null 2>/dev/null || true
    f=$(ls -t /tmp/zsp_icon_* 2>/dev/null | head -1)
    [ -n "${f:-}" ] && [ -f "$f" ] && cp "$f" "$ICON"
  fi
  [ -s "$ICON" ] || { echo "ERRO: nao consegui extrair o icone."; exit 4; }
  SHA=$(sha256sum "$ICON" | awk '{print $1}')
  EXP=$(( $(date +%s) + 600 ))
  AUTH=$(NOSTR_SECRET_KEY="$SIGN_WITH" "$NAK" event -k 24242 -c "Upload $SHA" \
          -t t=upload -t "x=$SHA" -t "expiration=$EXP" 2>/dev/null)
  [ -n "$AUTH" ] || { echo "ERRO: falha ao assinar auth Blossom."; exit 7; }
  B64=$(printf '%s' "$AUTH" | base64 -w0)
  HDRF=$(mktemp)
  curl -s -o /dev/null -D "$HDRF" -X PUT --data-binary @"$ICON" \
    -H "Authorization: Nostr $B64" -H "Content-Type: image/png" -H "Content-Digest: $SHA" \
    "$BLOSSOM/upload" 2>/dev/null
  STATUS_LINE=$(head -1 "$HDRF" | tr -d '\r')
  IDENT=$(grep -i '^x-identical-media:' "$HDRF" | head -1 | sed 's/^[^:]*://; s/[[:space:]]//g' | tr -d '\r')
  rm -f "$HDRF"
  echo "==> upload status: $STATUS_LINE / x-identical-media: ${IDENT:-<nenhum>}"
  case "$STATUS_LINE" in
    *" 200"*|*" 201"*) ICONHASH="$SHA" ;;
    *" 409"*)          ICONHASH="$IDENT" ;;
    *) echo "ERRO: status inesperado no upload do icone: $STATUS_LINE"; exit 5 ;;
  esac
fi

[ -n "$ICONHASH" ] || { echo "ERRO: nao foi possivel determinar o hash do icone."; exit 6; }
ICONURL="$BLOSSOM/$ICONHASH"
if ! curl -sfI "$ICONURL" >/dev/null 2>&1; then
  echo "ERRO: a URL do icone nao resolve (HEAD != 200). Abortando."
  exit 8
fi
echo "==> URL do icone: $ICONURL (acessivel)"

# ---------------------------------------------------------------------------
# 2) Config de publicacao = zapstore.yaml + linha icon: <URL no proprio Blossom>.
#    Como o prefixo == BLOSSOM_URL, o zsp usa a URL direto e NAO faz upload (sem 409).
#    O APK ja esta no nostr.download -> zsp HEAD-checa e pula o upload.
# ---------------------------------------------------------------------------
CFG="$HOME/zapstore-publish.yaml"
cp "$PROJ/zapstore.yaml" "$CFG"
printf '\nicon: %s\n' "$ICONURL" >> "$CFG"
echo "==> config de publicacao gerado em $CFG (icon embutido)"

# ---------------------------------------------------------------------------
# 3) Publicar (3 tentativas).
# ---------------------------------------------------------------------------
attempt=1
max=3
rc=1
while [ "$attempt" -le "$max" ]; do
  echo "===> publish tentativa $attempt de $max"
  "$ZSP" publish --quiet --skip-certificate-linking --overwrite-release "$CFG" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "===> publicado com sucesso na tentativa $attempt"
    exit 0
  fi
  echo "===> tentativa $attempt falhou (rc=$rc)"
  attempt=$((attempt + 1))
  [ "$attempt" -le "$max" ] && { echo "===> repetindo em 5s..."; sleep 5; }
done

echo "===> todas as $max tentativas falharam"
exit "$rc"
