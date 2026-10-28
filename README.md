# Murmur

Une app de dictée pour macOS qui fonctionne dans toutes les applications et tourne sur ton Mac. Tu maintiens une touche, tu parles, tu relâches : le texte nettoyé apparaît au curseur, dans l'app que tu utilises.

- **Maintenir pour parler :** maintiens le raccourci (par défaut `fn`) pour enregistrer. Relâche pour transcrire et coller.
- **Mains libres :** double tape sur le raccourci pour enregistrer sans rien tenir. Un tap de plus arrête. La session s'arrête et transcrit toute seule au bout de 5 minutes.
- **Échap :** arrête un enregistrement et le jette, ou annule une transcription déjà lancée. Murmur se contente d'observer la touche Échap : l'app dans laquelle tu écris la reçoit toujours.
- **Reconnaissance vocale :** whisper.cpp tourne sur ton Mac (modèle small ou medium). Tu peux basculer sur l'API Whisper de Groq ou d'OpenAI.
- **Nettoyage :** un LLM retire les mots de remplissage (euh, ben, genre...) et corrige la ponctuation et les majuscules, avec la typographie française. Si le LLM est désactivé, si tu es hors ligne ou s'il met trop de temps, Murmur colle la transcription brute.
- **Insertion :** colle le texte avec Cmd-V, ou le tape touche par touche. Par défaut le texte reste dans ton presse-papiers. Un réglage remet ton ancien presse-papiers à la place.
- **Pastille flottante :** indique si tu enregistres (`J'écoute` ou `Mains libres` avec un chrono), si la transcription est en cours, ou s'il y a une erreur.
- **Mode commande :** sélectionne un texte, maintiens **Option droite** et dicte une consigne (« rends ça plus formel », « traduis en anglais ») : la sélection est réécrite sur place.
- **Raccourcis vocaux :** dis « mon lien Calendly » et le texte associé dans `snippets.txt` est collé tel quel.
- **Historique et corrections :** une fenêtre pour relire et corriger chaque dictée. Un mot corrigé 3 fois de la même façon est appris et réécrit automatiquement ensuite. Un onglet de statistiques montre les mots dictés, le temps gagné et la latence.
- **Rien ne se perd :** l'audio d'une dictée qui échoue est gardé (menu « Réessayer »), l'API injoignable bascule sur whisper.cpp, et un texte dicté sans champ actif reste dans le presse-papiers (« Recoller la dernière dictée »).
- **Longues dictées plus rapides :** avec une API, la dictée est découpée aux pauses et envoyée pendant que tu parles.
- **Barre de menus :** activer ou désactiver, historique, recoller, réessayer, ouvrir à la connexion, ouvrir le fichier de réglages, le `.env` ou les raccourcis vocaux, recharger les réglages, gérer les autorisations, afficher le journal.
- Aucun compte, aucune télémétrie. Avec le modèle local, rien ne quitte ton Mac. Les appels API n'ont lieu que si tu choisis un fournisseur qui en a besoin.

## Installation

Prérequis : macOS 13 ou plus récent, et Swift (les Command Line Tools de Xcode suffisent : `xcode-select --install`).

```bash
git clone https://github.com/Judi-sa/Murmur.git
cd Murmur
```

```bash
./run.sh          # tout en un : dépendances, modèle, compilation, installation, lancement
./run.sh --log    # idem, puis affiche le journal en direct
```

Étape par étape, si tu préfères :

```bash
brew install whisper-cpp                 # fournit whisper-cli
./scripts/download-model.sh small        # ~466 Mo. "medium" (~1,5 Go) pour plus de précision
./scripts/build-app.sh --install         # compile, copie dans /Applications, lance l'app
```

Au premier lancement, Murmur crée `~/.config/murmur/config.json` et `~/.config/murmur/.env`. Une icône de micro apparaît dans la barre de menus.

## Autorisations à accorder

Ouvre **Réglages Système → Confidentialité et sécurité** et active **Murmur** dans chacune de ces rubriques :

| Autorisation | Pourquoi | Sans elle |
|---|---|---|
| **Micro** | Enregistrer ta voix | macOS la demande au premier enregistrement. Si tu refuses, la pastille affiche "Micro indisponible". |
| **Surveillance de l'entrée** | Détecter le raccourci et Échap dans tout le système | Le raccourci ne fait rien. L'icône de la barre de menus affiche ⚠︎. |
| **Accessibilité** | Envoyer Cmd-V ou les frappes à l'app active. Aussi nécessaire si ton raccourci est une combinaison comme `ctrl+option+space`, pour qu'elle ne soit pas tapée dans l'app. | Le texte arrive dans le presse-papiers mais n'est pas collé : la pastille affiche « Accessibilité à cocher : ⌘V pour coller » et le menu affiche une alerte. |

Murmur revérifie ces autorisations toutes les quelques secondes : pas besoin de relancer après les avoir accordées. **Autorisations…** dans la barre de menus ouvre les bons panneaux.

**Si tu utilises la touche `fn` / 🌐 :** va dans **Réglages Système → Clavier** et règle **"Appuyer sur la touche 🌐 pour"** sur **Ne rien faire**. Sinon macOS ouvre le sélecteur d'emojis ou sa propre dictée à chaque relâchement.

**Après une recompilation :** le script signe l'app ad hoc, donc macOS voit chaque nouvelle version comme une app différente. Les anciennes autorisations ne marchent plus, même si elles paraissent activées. Sélectionne Murmur dans Accessibilité et Surveillance de l'entrée, retire-la avec **−**, puis ajoute-la à nouveau. Tu peux aussi tout réinitialiser d'un coup :

```bash
tccutil reset Accessibility local.murmur.dictation
tccutil reset ListenEvent local.murmur.dictation
tccutil reset PostEvent local.murmur.dictation
```

Si tu as un certificat de signature de code, définis `MURMUR_SIGN_IDENTITY="Ton identité"` avant de compiler. Les autorisations sont alors conservées d'une version à l'autre.

## Clés API (facultatif)

Modifie `~/.config/murmur/.env`. Murmur le relit à chaque dictée, pas besoin de redémarrer.

```bash
GROQ_API_KEY=gsk_...         # API Whisper (rapide)
OPENAI_API_KEY=sk-...        # API Whisper et/ou nettoyage
ANTHROPIC_API_KEY=sk-ant-... # nettoyage
```

Murmur lit aussi un `.env` placé à côté de `Murmur.app`, ainsi que les variables d'environnement classiques.

## Réglages : `~/.config/murmur/config.json`

Après modification, clique sur **Recharger les réglages** dans la barre de menus. Tu peux n'indiquer que les clés à changer : les autres gardent leur valeur par défaut.

```jsonc
{
  "hotkey": "fn",                 // fn | right_option | right_command | right_control | right_shift
                                  // | left_option ... | ou une combinaison : "ctrl+option+space", "cmd+shift+f5"
  "commandHotkey": "right_option", // mode commande, touche modificatrice seule ; "" = désactivé
  "tapMaxDuration": 0.3,          // un appui plus court compte comme un tap
  "doubleTapWindow": 0.4,         // écart maximal entre les deux taps d'un double tap
  "maxRecordingSeconds": 300,     // arrêt automatique (le mode mains libres s'arrête et transcrit)
  "silenceThresholdDb": -45,      // les enregistrements plus faibles sont jetés ("Aucune parole détectée")
  "sounds": true,
  "logTranscripts": false,        // le journal ne contient jamais tes mots, sauf si true

  "transcription": {
    "provider": "local",          // local | groq | openai | auto (API si une clé existe, sinon local)
    "language": "fr",             // ou "en", "auto"... Une langue fixe est ~2x plus rapide en local (auto encode deux fois)
    "localModel": "small",        // small | medium | small.en | ... ou chemin absolu vers un .bin ggml
    "whisperBinary": "",          // vide = détection automatique de whisper-cli
    "threads": 0,                 // 0 = automatique
    "shrinkAudioContext": true,   // encode seulement la durée du clip, pas une fenêtre fixe de 30 s (gros gain sur CPU)
    "greedy": false,              // true = décodage plus rapide, un peu moins précis
    "groqModel": "whisper-large-v3-turbo",
    "openaiModel": "whisper-1",
    "prompt": "",                 // indice de vocabulaire : noms propres, jargon
    "bilingualHint": true,        // en "fr", amorce qui garde les termes anglais en anglais
    "fallbackToLocal": true,      // API injoignable après une nouvelle tentative : whisper.cpp prend le relais
    "streaming": true             // API seulement : découpe aux pauses et envoie pendant la dictée
  },

  "cleanup": {
    "provider": "auto",           // auto | anthropic | openai | groq | none
    "anthropicModel": "claude-haiku-4-5",
    "openaiModel": "gpt-4.1-mini",
    "groqModel": "openai/gpt-oss-20b",   // modèle de nettoyage ; les Llama ne sont pas ouverts à toutes les clés Groq
    "timeoutSeconds": 10,         // au-delà, la transcription brute est collée
    "systemPrompt": "",           // vide = prompt intégré (en français)
    "commandGroqModel": "openai/gpt-oss-120b"  // modèle Groq du mode commande
  },

  "insertion": {
    "method": "paste",            // paste (presse-papiers + Cmd-V) | type (frappes clavier simulées)
    "restoreClipboard": false,    // false : la transcription reste dans le presse-papiers ; true : l'ancien contenu revient
    "trailingSpace": true
  },

  "vocabulary": {
    "enabled": true,              // false = ~/.config/murmur/vocabulary.txt est ignoré
    "useInTranscription": true,   // les termes complètent le prompt soufflé à Whisper
    "useInCleanup": true          // les termes et les règles "=>" sont ajoutés au prompt de nettoyage
  },

  "appProfiles": {
    "enabled": true,              // false = l'application active n'influence plus rien
    "mentionAppInPrompt": true,   // ajoute "L'utilisateur dicte dans <App>." au prompt de nettoyage
    "defaultInstruction": "",     // consigne appliquée quelle que soit l'application
    "profiles": [                 // exemples livrés : « Assistants IA » actif, les autres "enabled": false
      {
        "name": "Terminal",
        "bundleIDs": ["com.apple.Terminal", "com.googlecode.iterm2"],
        "instruction": "N'ajoute aucune ponctuation qui n'a pas été dictée...",
        "disableCleanup": false,  // true = colle la transcription brute dans cette app
        "enabled": false          // false = profil présent mais ignoré
      }
    ]
  },

  "history": {
    "enabled": false,             // false par défaut : AUCUN historique n'est écrit tant que tu ne l'actives pas
    "maxEntries": 2000,           // plafond de lignes, les plus anciennes sont élaguées
    "suggestionMinOccurrences": 3, // seuil d'affichage dans « Suggestions de vocabulaire »
    "learnThreshold": 3           // corrections identiques (fenêtre Historique) avant application automatique
  },

  "pill": { "enabled": true, "position": "bottom" }   // bottom | top
}
```

(Le vrai fichier doit être du JSON pur, sans les commentaires.)

### Dictionnaire personnel : `~/.config/murmur/vocabulary.txt`

Les mots que Whisper écorche systématiquement (noms propres, marques, jargon). Un terme par ligne ; les lignes vides et celles qui commencent par `#` sont ignorées. La forme `erreur => correction` force une correction systématique.

```
Murmur
Mon Entreprise
Prénom Nom
Mian Mian => Murmur
```

Les règles `=>` sont aussi appliquées **directement au texte final**, après le nettoyage, sur des mots entiers et sans tenir compte de la casse ni des accents : l'orthographe choisie gagne même si le LLM l'ignore ou si le nettoyage est sauté. Les règles apprises depuis la fenêtre Historique sont précédées d'une ligne `# auto, appris le …`.

Évite les règles purement typographiques (`c'est => c’est`) : Whisper imite le prompt et se met à semer des apostrophes au milieu des mots. Murmur convertit déjà l'apostrophe droite en apostrophe française et retire les apostrophes parasites (« les’ images »).

Le fichier est relu à chaque dictée, pas besoin de redémarrer. Les termes sont soufflés à Whisper (local et API) en complément de `transcription.prompt`, qui reste prioritaire, et tronqués à la limite de 224 tokens de l'initial prompt. Ils sont aussi passés au LLM de nettoyage, avec la consigne de corriger tout mot phonétiquement proche. Fichier absent ou vide : rien ne change.

### Profils par application : `appProfiles`

Murmur note quelle application avait le focus **au moment où tu commences à parler** (pas à la fin : la pastille et le collage peuvent déplacer le focus entre-temps) et adapte le nettoyage en conséquence.

- `enabled` : `false` coupe toute la fonctionnalité, le prompt redevient exactement celui d'avant.
- `mentionAppInPrompt` : ajoute la phrase `L'utilisateur dicte dans <App>.` au prompt système. Activé par défaut, c'est le seul changement de comportement par défaut ; mets `false` si tu veux un prompt strictement inchangé.
- `defaultInstruction` : consigne libre appliquée à toutes les applications.
- `profiles` : une liste de profils. Le **premier** profil activé dont `bundleIDs` contient l'identifiant de l'app gagne ; un seul s'applique, pour que le prompt reste prévisible.
  - `name` : purement descriptif.
  - `bundleIDs` : identifiants de bundle ciblés, comparés sans tenir compte de la casse. Pour connaître celui d'une app : `osascript -e 'id of app "Slack"'`.
  - `instruction` : texte libre ajouté au prompt système du nettoyage.
  - `disableCleanup` : `true` saute complètement le LLM pour cette app et colle la transcription brute.
  - `enabled` : `false` par défaut sur tous les exemples livrés, donc rien ne change tant que tu n'en actives pas un.

Le profil **Assistants IA** est actif d'emblée : Claude, VS Code, Grok, ChatGPT et Cursor. Ta dictée y devient un prompt structuré, avec des paragraphes, et une liste à puces quand tu énumères, sans perdre de détail technique. Mets son `enabled` à `false` dans une copie de la liste `profiles` pour le couper.

Les autres exemples pré-remplis sont Terminal / iTerm2 (aucune ponctuation ajoutée, identifiants de code respectés), Mail (ton formel), Gmail dans le navigateur (mêmes consignes) et Messagerie rapide pour Slack, Notes et Messages (ton direct et concis). Murmur ne voit que l'application, pas l'onglet : le profil « navigateur » s'applique à tout le navigateur, pas seulement à Gmail.

La ligne de journal de fin de dictée indique l'app détectée : `Dictée 4.5 s audio → transcription 0.93 s (groq), total 1.62 s, 49 caractères, dans Terminal`.

### Historique des dictées et suggestions de vocabulaire : `history`

**Désactivé par défaut, et c'est volontaire :** l'historique contient le *texte* de tes dictées. Tant que `history.enabled` reste `false`, `~/.config/murmur/history.jsonl` n'est pas créé et rien n'est écrit, dans le même esprit que `logTranscripts`.

Pour l'activer, ajoute dans `config.json` :

```json
"history": { "enabled": true }
```

puis **Recharger les réglages** dans la barre de menus.

Chaque dictée ajoute alors une ligne JSON : horodatage ISO 8601, durée audio, durée de transcription, durée totale, provider utilisé, identifiant de bundle et nom de l'app active, texte brut et texte nettoyé. Le fichier est créé en `chmod 600` (lisible par toi seul) et plafonné à `maxEntries` lignes (2000 par défaut) : au-delà, les plus anciennes sont élaguées. L'écriture se fait sur une file dédiée, après la transcription : elle ne retarde jamais le collage du texte et une erreur d'écriture ne fait pas échouer une dictée.

**Suggestions de vocabulaire.** Le menu de la barre de menus contient un sous-menu **Suggestions de vocabulaire**. Il compare, sur les 500 dernières dictées, le texte brut et le texte nettoyé mot à mot et repère les mots que le LLM corrige toujours de la même façon (`murmure → Murmur`). La ponctuation, la casse, les accents et les tics de langage supprimés par le prompt sont ignorés, et seuls les mots phonétiquement proches sont retenus : une reformulation n'est pas une suggestion. Les corrections vues au moins `suggestionMinOccurrences` fois (3 par défaut) apparaissent avec leur nombre d'occurrences ; un clic ajoute la ligne `erreur => correction` à `vocabulary.txt`, qui est relu à la dictée suivante. Les règles déjà présentes dans le dictionnaire ne sont plus proposées.

Historique désactivé : le sous-menu le dit et ne propose rien.

### Fenêtre Historique et apprentissage des corrections

Menu **Historique et corrections…** :

- **Dictées :** toutes les dictées, de la plus récente à la plus ancienne, avec recherche et filtre par app. Clique sur une dictée, corrige le texte, puis **Enregistrer la correction** (⌘S). Les mots remplacés sont comptés : à `learnThreshold` corrections identiques (3 par défaut), la règle `erreur => correction` entre dans `vocabulary.txt` et s'applique à chaque dictée suivante. Seuls comptent les remplacements de 1 à 3 mots : un passage largement réécrit est une reformulation, pas une faute à rejouer. La casse seule et le type d'apostrophe ne comptent pas.
- **Corrections apprises :** chaque correction avec son compteur (`2/3`) ou le statut « Appliquée ». **Oublier** efface le compteur et retire la règle du dictionnaire.
- **Statistiques :** mots dictés (au total et aujourd'hui), temps gagné par rapport à une frappe à 40 mots/min, latence médiane et p90, mots par jour sur 14 jours, dictées par app, échecs relevés dans le journal.

Les compteurs vivent dans `~/.config/murmur/corrections.json` (`chmod 600`).

### Mode commande : `commandHotkey`

1. Sélectionne un texte dans n'importe quelle app.
2. Maintiens **Option droite** (pastille violette « Commande ») et dicte la consigne : « rends ça plus formel », « raccourcis en trois phrases », « traduis en anglais ».
3. Relâche : le texte réécrit remplace la sélection.

La sélection est lue par l'accessibilité, ou à défaut par un ⌘C simulé, puis ton presse-papiers est remis en place. Sans sélection, la pastille affiche « Sélectionne d'abord un texte » et rien n'est modifié. Avec Groq, la réécriture passe par `commandGroqModel` (`openai/gpt-oss-120b`), plus capable que le modèle de nettoyage ; avec Anthropic ou OpenAI, le modèle de nettoyage est réutilisé. Option droite + une autre touche (caractère spécial) annule la commande. `"commandHotkey": ""` désactive le mode.

### Raccourcis vocaux : `~/.config/murmur/snippets.txt`

Une ligne par raccourci, `déclencheur => texte` (`\n` pour un saut de ligne) :

```
mon lien calendly => https://calendly.com/ton-lien
ma signature => Bien cordialement,\nPrénom Nom
```

Quand la dictée entière est un déclencheur, éventuellement précédé de « insère », le texte est collé tel quel, sans nettoyage. La casse, les accents et la ponctuation ne comptent pas. Un déclencheur prononcé au milieu d'une phrase n'est pas remplacé. Relu à chaque dictée. Menu : **Ouvrir les raccourcis vocaux**.

### Fiabilité : découpage, repli local, audio gardé

- **Découpage aux pauses** (`transcription.streaming`, API seulement) : au-delà de 12 s de parole, chaque pause de 0,35 s ferme un morceau, envoyé aussitôt avec la fin du morceau précédent comme contexte. Au relâchement, seule la fin reste à transcrire. Mesuré : une dictée de 93 s revient en 0,9 à 1,4 s au lieu de 2,8 à 4,6 s. Sous 30 s le gain est nul, Groq ayant surtout un coût fixe par requête. Si un morceau échoue, l'enregistrement complet est retranscrit d'un bloc.
- **Délai adapté et nouvelle tentative :** la requête de transcription expire après `8 s + la moitié de la durée audio` (60 s au plus), puis est relancée une fois.
- **Repli local** (`transcription.fallbackToLocal`) : si l'API reste injoignable, whisper.cpp prend le relais (pastille « API injoignable : transcription locale »), à condition d'être installé avec son modèle.
- **Audio gardé :** si la dictée échoue malgré tout, l'audio va dans `~/.config/murmur/failed/` (dossier `700`, 5 fichiers au plus) et **Réessayer la dernière dictée échouée** le relance. Il est supprimé après une nouvelle tentative réussie.
- **Collage dans le vide :** si aucun champ ne peut recevoir le texte (bureau, Stage Manager, Dock, Finder hors renommage), il reste dans le presse-papiers et la pastille affiche « Copié : ⌘V pour coller ». Dans le doute (apps Electron), Murmur colle. **Recoller la dernière dictée** recolle le dernier texte au curseur.
- **Génériques inventés :** les « Sous-titrage Société Radio-Canada » et autres « Amara.org » que Whisper invente dans le silence sont retirés. « Merci d'avoir regardé » ou « Abonnez-vous » ne sont retirés que s'ils forment toute la transcription.

### Vitesse du modèle local

whisper.cpp est rapide sur Apple Silicon. Sur un Mac Intel, il tourne uniquement sur le processeur. Sur un i5 quatre cœurs, un clip de 7 secondes avec le modèle `small` prend environ 9 à 11 s avec `"language"` fixé, et environ 20 s avec `"auto"`, qui ajoute une passe complète de 30 secondes. Pour accélérer :

1. Fixe `"language"` sur la langue que tu parles vraiment (`"fr"` par défaut). C'est ce qui compte le plus.
2. Mets `"greedy": true`.
3. Utilise `"provider": "groq"` quand tu es en ligne : c'est en général bien en dessous d'une seconde. Avec `"auto"`, Murmur passe par Groq dès qu'une clé existe.

`medium` est environ 3 fois plus lent que `small`. Il ne vaut le coup que sur Apple Silicon.

### 100 % hors ligne

Mets `"transcription.provider": "local"` et `"cleanup.provider": "none"`. Laisser le nettoyage sur `auto` marche aussi hors ligne : quand l'appel réseau échoue, Murmur colle la transcription brute.

## Fonctionnement du raccourci

| Tu fais | Murmur fait |
|---|---|
| Maintien de 0,3 s ou plus, puis relâchement | Enregistre pendant le maintien, puis transcrit et colle |
| Un seul tap | Rien (le court extrait est jeté) |
| Tap, tap | Lance une session mains libres (pastille 🔒 avec chrono, compte à rebours pendant la dernière minute) |
| Tap pendant le mode mains libres | Arrête, transcrit, colle |
| Échap pendant l'enregistrement | Jette l'enregistrement |
| Échap pendant la transcription | Arrête whisper-cli ou la requête API en cours. Rien n'est collé. |
| Autre touche pendant le maintien d'un raccourci modificateur | Considéré comme un raccourci clavier (ex. ⌘ droit + C). L'enregistrement est jeté. |
| Maintien d'Option droite sur une sélection, puis relâchement | Mode commande : la consigne dictée réécrit la sélection |

## Dépannage

- **Rien ne se passe quand tu appuies sur le raccourci :** regarde l'icône de la barre de menus. Si elle affiche ⚠︎, accorde Surveillance de l'entrée. Si tu viens de recompiler, vois **Après une recompilation** plus haut.
- **Le texte n'est pas collé, mais il est dans le presse-papiers :** accorde Accessibilité (la pastille « Accessibilité à cocher » et l'alerte du menu le confirment ; c'est le cas après chaque recompilation). Si la pastille a affiché « Copié : ⌘V pour coller », Murmur n'a trouvé aucun champ actif : clique dans le champ et colle.
- **Une dictée a échoué :** menu **Réessayer la dernière dictée échouée**.
- **Tester la transcription sans le raccourci :**
  ```bash
  say -v Thomas -o /tmp/t.aiff "euh bon alors, je teste la dictée, genre, pour voir si ça marche"
  ffmpeg -y -i /tmp/t.aiff -ar 16000 -ac 1 /tmp/t.wav
  /Applications/Murmur.app/Contents/MacOS/Murmur --transcribe /tmp/t.wav
  ```
- **Journal :** `~/Library/Logs/Murmur.log`. Il contient seulement les durées et les erreurs, jamais tes mots sauf si `logTranscripts` est activé. L'historique `~/.config/murmur/history.jsonl`, lui, contient le texte de tes dictées, mais il n'existe que si tu as mis `history.enabled` à `true`.

## Organisation du code

```
run.sh                      dépendances, compilation, installation, lancement
scripts/build-app.sh        construit et signe Murmur.app
scripts/download-model.sh   télécharge un modèle ggml
Sources/Murmur/
  main.swift                point d'entrée + mode test --transcribe
  AppDelegate.swift         barre de menus, ouverture à la connexion, autorisations
  HotkeyMonitor.swift       CGEventTap : maintien/relâchement du raccourci, Échap en écoute passive
  DictationController.swift machine à états : maintien / double tap mains libres / commande / Échap / arrêt auto,
                            pipeline, morceaux, audio gardé (FailedAudio)
  AudioRecorder.swift       AVAudioEngine 16 kHz mono, découpage aux pauses, silences retirés, vumètre
  Transcriber.swift         whisper.cpp en sous-processus, API Whisper Groq/OpenAI, nouvelle tentative, repli local
  Cleaner.swift             nettoyage par LLM (Anthropic / OpenAI / Groq)
  TextInserter.swift        presse-papiers + Cmd-V ou frappes, restauration facultative du presse-papiers
  Pill.swift                pastille flottante non activante
  Config.swift              config.json, .env, journal
  Vocabulary.swift          dictionnaire personnel vocabulary.txt
  AppContext.swift          app active + profils par application
  History.swift             historique history.jsonl (opt-in) + suggestions de vocabulaire
  HistoryWindow.swift       fenêtre Historique : dictées, corrections apprises, statistiques
  Learning.swift            apprentissage des corrections corrections.json
  Commander.swift           mode commande : réécriture de la sélection
  Snippets.swift            raccourcis vocaux snippets.txt
```

## Licence

MIT : tu peux utiliser, modifier et redistribuer Murmur librement, en gardant la mention de copyright. Voir [LICENSE](LICENSE).
