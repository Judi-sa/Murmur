#!/bin/bash
# Télécharge un modèle ggml de whisper.cpp dans ~/.config/murmur/models.
# Usage : scripts/download-model.sh [small|medium|small.en|medium.en|large-v3-turbo]   (par défaut : small)
set -euo pipefail
MODEL="${1:-small}"
DIR="$HOME/.config/murmur/models"
FILE="$DIR/ggml-$MODEL.bin"
mkdir -p "$DIR"
if [[ -s "$FILE" ]]; then echo "Déjà présent : $FILE"; exit 0; fi
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
echo "Téléchargement de $URL"
curl -fL --progress-bar -o "$FILE.part" "$URL"
mv "$FILE.part" "$FILE"
echo "Enregistré : $FILE"
echo "Mets \"localModel\": \"$MODEL\" dans ~/.config/murmur/config.json, puis Recharger les réglages."
