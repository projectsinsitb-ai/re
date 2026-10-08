#!/usr/bin/env bash
# croc-receive.sh — recibir archivo con croc via Docker

mkdir -p "$HOME/.config/croc"

read -p "🔑 Código de recepción: " CODIGO

if [ -z "$CODIGO" ]; then
  echo "❌ No has introducido ningún código"
  exit 1
fi

echo "📥 Recibiendo con código: $CODIGO"

docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -v "$(pwd):/transfer" \
  -v "$HOME/.config/croc:/.config/croc" \
  -w /transfer \
  schollz/croc --yes receive "$CODIGO"
