#!/bin/sh
# Publie une version de PTZBot pour Mac sur GitHub (spec distribution, section 5) : verifications, numeros,
# compilation Release signee par le certificat de Djoko, .dmg signe par Sparkle (cle du trousseau), controle de
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
# NOTARISER=1 (desactive par defaut) : notarisation du .dmg, avec PROFIL_NOTARISATION, le profil que
# notarytool store-credentials a range dans le trousseau ; il faut alors un Developer ID pour IDENTITE_SIGNATURE.
# Produits : mac/app/build/publication/X.Y.Z/ ; compilation dans DD (par defaut DerivedData/ptzbot-publication).
set -eu
cd "$(dirname "$0")/../mac/app"
# L'identite de signature de la version publiee, a ce seul endroit : le certificat auto-signe de Djoko, trouve par
# son nom dans le trousseau (les compilations de travail et les tests restent ad hoc).
IDENTITE_SIGNATURE=${IDENTITE_SIGNATURE:-Djoko-cli Code Signing}
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
exec /usr/bin/python3 ../../outils/publication.py publier "$@" --identite "$IDENTITE_SIGNATURE" \
  --auteur Djoko-cli --etiquette ptzbot-v --flux appcast.xml --licence ../../outils/Sparkle-LICENSE.txt \
  --notes ../../NOTES-VERSIONS.md --sans-bac-a-sable \
  --nom-app PTZBot --fichier PTZBot --depot-github Djoko-cli/obsbot-nacelle \
  --projet PTZBot.xcodeproj --schema PTZBot --cible PTZBot \
  --test 'cd ../../Packages/NacelleProtocol && swift test' \
  --test 'cd ../ptzd && swift test' \
  --test 'cd PTZBotKit && swift test' \
  --test '/usr/bin/python3 -m unittest discover -s ../../outils/tests' \
  --test 'bash -n ../../scripts/install-mac.sh' \
  --textes PTZBot/Localizable.xcstrings --textes PTZBot/InfoPlist.xcstrings \
  --textes PTZBotKit/Sources/PTZBotKit/Resources/Localizable.xcstrings
