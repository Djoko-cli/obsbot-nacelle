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
# IDENTITE_SIGNATURE : le nom du certificat de signature ; sans lui, l'unique identite valide « Developer ID
# Application » du trousseau (zero ou plusieurs : refus). Son nom complet porte le nom de la personne et son
# identifiant d'equipe : il n'est ecrit nulle part dans le depot, ni dans une sortie publiee.
# Notarisation du .dmg (soumission a Apple, agrafe, evaluation de Gatekeeper) : par defaut avec un Developer ID,
# NOTARISER=0 la coupe ; NOTARISER=1 l'impose. PROFIL_NOTARISATION : le profil que notarytool store-credentials a
# range dans le trousseau (par defaut ptzbot-notarisation).
# Produits : mac/app/build/publication/X.Y.Z/ ; compilation dans DD (par defaut DerivedData/ptzbot-publication).
set -eu
cd "$(dirname "$0")/../mac/app"
# L'identite de signature de la version publiee : IDENTITE_SIGNATURE si elle est donnee (le certificat auto-signe
# « Djoko-cli Code Signing » marche encore, sans notarisation), sinon publication.py prend l'unique Developer ID du
# trousseau. Les compilations de travail et les tests restent ad hoc.
PROFIL_NOTARISATION=${PROFIL_NOTARISATION:-ptzbot-notarisation}
export PROFIL_NOTARISATION
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
exec /usr/bin/python3 ../../outils/publication.py publier "$@" ${IDENTITE_SIGNATURE:+--identite "$IDENTITE_SIGNATURE"} \
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
