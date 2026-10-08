#!/usr/bin/env bash
# croc-send.sh — enviar uno o varios archivos con croc via Docker

ls -la

pwd

mkdir -p "$HOME/.config/croc"

read -p "📦 Archivo(s) a enviar (separados por espacio): " -a ARCHIVOS

if [ ${#ARCHIVOS[@]} -eq 0 ]; then
  echo "❌ No has introducido ningún archivo"
  exit 1
fi

# Verificar que todos existen antes de enviar
ERROR=0
for ARCHIVO in "${ARCHIVOS[@]}"; do
  if [ ! -f "$ARCHIVO" ]; then
    echo "❌ Archivo '$ARCHIVO' no encontrado en $(pwd)"
    ERROR=1
  fi
done

if [ $ERROR -eq 1 ]; then
  exit 1
fi

echo "📤 Enviando: ${ARCHIVOS[*]}"

docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  -v "$(pwd):/transfer" \
  -v "$HOME/.config/croc:/.config/croc" \
  -w /transfer \
  schollz/croc send "${ARCHIVOS[@]}"
