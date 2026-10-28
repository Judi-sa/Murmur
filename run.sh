#!/bin/bash
# Lance Murmur en une commande : vérifie les dépendances, compile, installe dans /Applications et démarre l'app.
# Usage : ./run.sh          compile, installe et lance
#         ./run.sh --log    idem, puis affiche le journal en direct (Ctrl-C pour quitter le journal, l'app continue)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="$HOME/.config/murmur/config.json"
LOG="$HOME/Library/Logs/Murmur.log"

# 1. whisper.cpp
if ! command -v whisper-cli >/dev/null && [[ ! -x /opt/homebrew/bin/whisper-cli && ! -x /usr/local/bin/whisper-cli ]]; then
  echo "→ whisper-cli absent, installation via Homebrew..."
  brew install whisper-cpp
fi

# 2. Modèle Whisper configuré (small par défaut)
MODEL="small"
if [[ -f "$CONFIG" ]]; then
  MODEL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("transcription",{}).get("localModel","small"))' "$CONFIG" 2>/dev/null || echo small)"
fi
if [[ "$MODEL" != /* && "$MODEL" != ~* ]]; then
  ./scripts/download-model.sh "$MODEL"
fi

# 3. Compilation, installation, lancement
./scripts/build-app.sh --install

echo
echo "Murmur tourne dans la barre de menus (icône micro)."
echo "Si l'icône affiche ⚠︎ : Réglages Système → Confidentialité et sécurité → Surveillance de l'entrée + Accessibilité."
echo "Journal : $LOG"

if [[ "${1:-}" == "--log" ]]; then
  touch "$LOG"
  tail -n 20 -f "$LOG"
fi
