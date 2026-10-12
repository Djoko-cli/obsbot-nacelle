#!/bin/sh
# Publie une version de PTZBot pour Mac sur GitHub (spec distribution, section 5) : verifications, numeros,
# compilation Release signee Developer ID et notarisee, .dmg signe par Sparkle (cle du trousseau), controle de
# fuite, version publiee (etiquette ptzbot-vX.Y.Z, avec le .dmg), puis le flux des mises a jour
# (mac/app/appcast.xml, qui garde toutes les versions) commite sur main et pousse aussitot, .dmg sur le Bureau.
# Le .dmg porte aussi la licence de Sparkle 2.10.0 (outils/Sparkle-LICENSE.txt, le fichier LICENSE de l'etiquette
# 2.10.0, entier) ; le commit du flux est signe Djoko-cli, a l'adresse noreply de GitHub.
# Repris de maillage-thread ; la logique est dans outils/publication.py, ses tests dans outils/tests.
#   outils/publier.sh X.Y.Z [--sans-bureau]
# La repetition, sans GitHub ni Bureau (spec, section 10), avec la cle du trousseau, ou une paire d'essai :
#   outils/publier.sh X.Y.Z --repetition DOSSIER --url-base URL [--cle-privee FICHIER --cle-publique CLE]
#                           [--trousseau TROUSSEAU] [--sans-tests]
# SPARKLE_BIN : le dossier bin de l'archive de Sparkle 2.10.0 (sign_update, generate_keys) ; par defaut, celui que
# le gestionnaire de paquets de Xcode a resolu dans DD (SourcePackages/artifacts/sparkle/Sparkle/bin).
# Depuis la 1.0.7 (decision de Djoko du 12/10/2026), une version publiee est signee par son Developer ID et notarisee :
# IDENTITE_SIGNATURE vaut « Developer ID Application » (l'unique identite de ce nom dans le trousseau, trouvee par
# son prefixe ; zero ou plusieurs : refus) et NOTARISER vaut 1, par defaut. Le nom complet de l'identite porte le nom
# legal de la personne et son identifiant d'equipe : il figure dans la signature des versions publiees et nulle part
# ailleurs (ni depot, ni commits, ni notes, ni flux, ni journaux affiches).
# Le cliquet : hors --repetition, toute autre identite et tout NOTARISER different de 1 sont refuses ici ; la
# repetition seule peut signer autrement (IDENTITE_SIGNATURE, NOTARISER=0). PROFIL_NOTARISATION : le profil que
# notarytool store-credentials a range dans le trousseau (par defaut djoko-notarisation, le profil commun a toutes
# les apps de Djoko).
# Produits : mac/app/build/publication/X.Y.Z/ ; compilation dans DD (par defaut DerivedData/ptzbot-publication).
set -eu
cd "$(dirname "$0")/../mac/app"
# L'identite de signature de la version publiee, a ce seul endroit : le Developer ID, generique ; publication.py
# prend l'unique Developer ID du trousseau (son nom complet n'est ecrit nulle part ici). Les compilations de travail
# et les tests restent ad hoc.
IDENTITE_SIGNATURE=${IDENTITE_SIGNATURE:-Developer ID Application}
NOTARISER=${NOTARISER:-1}
PROFIL_NOTARISATION=${PROFIL_NOTARISATION:-djoko-notarisation}
export NOTARISER PROFIL_NOTARISATION
# Le cliquet : hors repetition, jamais d'autre signature (un retour au certificat auto-signe ramenerait l'alerte
# « l'app differe » de macOS et le blocage de Gatekeeper).
repetition=0
for x in "$@"; do
  case $x in --repetition|--repetition=*) repetition=1;; esac
done
if [ $repetition = 0 ] && { [ "$IDENTITE_SIGNATURE" != "Developer ID Application" ] || [ "$NOTARISER" != 1 ]; }; then
  echo "publier.sh : une version publiee est signee par le Developer ID et notarisee (IDENTITE_SIGNATURE, NOTARISER)" >&2
  exit 1
fi
# publication.py cherche lui-meme l'identite generique par son prefixe ; un nom donne (repetition) lui est passe.
if [ "$IDENTITE_SIGNATURE" != "Developer ID Application" ]; then
  set -- "$@" --identite "$IDENTITE_SIGNATURE"
fi
DD=${DD:-$HOME/Library/Developer/Xcode/DerivedData/ptzbot-publication}
export DD
if [ -z "${SPARKLE_BIN:-}" ]; then
  # Les outils de Sparkle viennent du paquet resolu (version figee dans project.yml) : le projet est genere et ses
  # paquets resolus dans DD avant les verifications (le .xcodeproj n'est pas versionne, l'arbre reste propre).
  xcodegen generate --quiet
  xcodebuild -resolvePackageDependencies -project PTZBot.xcodeproj -scheme PTZBot -derivedDataPath "$DD" >/dev/null
  SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
fi
export SPARKLE_BIN
exec /usr/bin/python3 ../../outils/publication.py publier "$@" \
  --auteur Djoko-cli --etiquette ptzbot-v --flux appcast.xml --licence ../../outils/Sparkle-LICENSE.txt \
  --notes ../../NOTES-VERSIONS.md --sans-bac-a-sable \
  --nom-app PTZBot --fichier PTZBot --depot-github Djoko-cli/obsbot-nacelle \
  --projet PTZBot.xcodeproj --schema PTZBot --cible PTZBot \
  --test 'cd ../../Packages/NacelleProtocol && swift test' \
  --test 'cd ../ptzd && swift test' \
  --test 'cd ../talkd && swift test' \
  --test 'cd PTZBotKit && swift test' \
  --test '/usr/bin/python3 -m unittest discover -s ../../outils/tests' \
  --test 'bash -n ../../scripts/install-mac.sh' \
  --textes PTZBot/Localizable.xcstrings --textes PTZBot/InfoPlist.xcstrings \
  --textes PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
