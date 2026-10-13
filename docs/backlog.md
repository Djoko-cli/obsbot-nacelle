# Pour plus tard

Idées validées par l'usage, pas encore planifiées.

## Sensibilité du joystick

Un réglage dans l'app (par exemple lente, normale, rapide, ou un curseur) qui met à l'échelle les vitesses envoyées à `ptzd`. Le plafond reste celui de `ptzd` (pan 80, tilt 120).


## Une seule adresse pour le Mac

Ne plus saisir le nom Tailscale : l'app pourrait retenir l'adresse Tailscale du Mac reçue à l'appairage, ou joindre l'IP locale du Mac en 4G par le routage de sous-réseau de Tailscale (à vérifier : comment ce trafic arrive à `ptzd`, et TLS côté app pour cette adresse).

## Exposition automatique

Un bouton dans l'app iOS, et dans le panneau du Mac, pour l'exposition automatique, à côté du bouton d'enregistrement. Le SDK OBSBOT expose le mode d'exposition (`cameraSetExposureModeR`), l'exposition sur le visage (`cameraSetFaceAER`), le verrouillage (`cameraSetAELockR`) et la correction d'exposition (`cameraSetPAEEvBiasR`). À vérifier d'abord : la commande UVC standard du mode d'exposition (`CT_AE_MODE`), que `ptzd` envoie déjà par IOKit pour la nacelle, éviterait le SDK et ses 4,2 s de lancement. Comportement voulu par Majid : **activé**, la caméra est en exposition automatique continue ; **désactivé**, elle revient au réglage fait dans OBSBOT Center. Il faut donc lire et retenir le réglage en place (mode, valeurs manuelles, correction) avant d'activer, puis le remettre à la désactivation, y compris après un redémarrage de `ptzd`.

## Licence de redistribution du SDK OBSBOT

Après B2, quand l'app sera présentable : demander à OBSBOT une licence pour **livrer `libdev.dylib` en binaire dans PTZBot.app**. L'app est gratuite et open source, et les en-têtes ne seraient pas redistribués. Avec cette licence, l'image disque marcherait dès l'installation, sans étape manuelle, et la question de livrer `obsbot-ai` dans B2 serait réglée.

À demander précisément :
- l'autorisation de re-signer la bibliothèque, ou de la charger avec la signature de l'éditeur ;
- l'attribution ;
- les versions et les mises à jour ;
- un éventuel usage commercial.

Garder l'installation manuelle par l'app comme repli. Claude peut rédiger la demande en brouillon ; Majid l'envoie.

## Rotation de obsbot-ai.log

Le journal `obsbot-ai.log` (sortie du SDK et de `obsbot-ai`, dans le dossier des journaux de `ptzd`) grossit sans limite. Depuis le mode résident, le SDK reste chargé jusqu'à 10 minutes après chaque activité : son bruit peut croître plus vite qu'avant. À mesurer au banc (croissance sur 10 minutes de mode résident) ; si elle est nette, faire tourner le fichier à une taille maximale (par exemple 1 Mo, en gardant une ou deux copies), au lancement de l'utilitaire plutôt qu'en cours d'exécution, pour ne pas couper une ligne que le SDK est en train d'écrire.

## Silence de comblement à la minuterie de ClipRecorder

Les fragments MP4 de l'enregistrement iOS ne se ferment que si la piste son avance. Sans son du tout (flux sans piste audio, interruption audio en cours d'enregistrement), le filet de sécurité des fragments ne joue plus : la finalisation normale reste complète, mais une app tuée ou une finalisation ratée perd ce qui suit la perte du son. Correction : la minuterie de `ClipRecorder` écrit elle-même du silence quand le son a plus de 0,5 s de retard, jusqu'à 0,25 s avant la dernière image, ancré sur `sessionStart`. Puis un mini-banc de synchronisation (claquement de mains) pour vérifier que le son réel reprend sans décalage.

## Voix de l'iPhone dans les vidéos du bouton rec

Pendant un enregistrement (bouton rec de l'app iOS), ajouter à la vidéo la voix captée par le micro de l'iPhone quand on maintient le bouton « parler » (spec `2026-10-09-parler-ios-design.md`), à la source, en plus du son de la caméra. Aujourd'hui, la voix n'y arrive qu'indirectement, par le haut-parleur du Mac capté par le micro de la caméra. À trancher : mixer les deux sons dans une seule piste AAC ou garder deux pistes, et le recalage dans le temps entre le micro de l'iPhone et le son reçu.

## Pincer pour zoomer sur la vidéo (app iOS)

Un geste de pincement à deux doigts sur la vidéo pour zoomer **l'affichage seul**, sur l'iPhone (décision de Majid le 09/10) : un zoom numérique de la vue, sans ordre à la caméra, donc sans effet sur HomeKit ni sur les enregistrements. Avec un glissement à deux doigts pour se déplacer dans l'image zoomée, et un double tap pour revenir à l'image entière. Sans conflit avec le joystick ni avec le tap du mode épuré.

## Échec périmé dans l'état de talkd (relecture finale du 12/10, M1)

Un `failure` écrit par un ancien talkd (port occupé, puis Talkback éteint) reste dans `talkd-state.json` : aucun talkd ne réécrit le fichier tant que l'agent est désinscrit. Au rallumage, le panneau affiche « Arrêté : le port UDP est déjà utilisé » avant que le nouveau talkd ait démarré, et la relance automatique des 4 s ne se fait pas (elle ne vise que « Démarrage… »). Correction possible : ignorer un état dont `since` précède la dernière inscription, ou effacer le fichier à l'extinction. Cas rare : il faut un port occupé juste avant.

## PTZBot iOS sur TestFlight, puis l'App Store (décision de Majid, 12/10/2026)

Sous-projet à part, après le Developer ID (1.0.7) et B3. Certificat « Apple Distribution » et profil App Store créés par Xcode (signature automatique), fiche de l'app dans App Store Connect. Étape 1 : TestFlight pour les appareils de Majid (testeurs internes, sans relecture d'Apple). Étape 2, si décidée : App Store public, avec relecture d'Apple (l'app dépend d'un Mac et d'une OBSBOT : vidéo de démonstration probable), politique de confidentialité en ligne, étiquettes de confidentialité, déclaration de chiffrement (exemption standard TLS/WebRTC), question du nom et de la marque vis-à-vis d'OBSBOT.

## Utilitaire de capture de PTZBot (après B3, décision de Majid du 12/10/2026)

L'essai du 12/10 a montré que macOS attribue l'accès à la caméra au programme qui l'ouvre (ffmpeg de Homebrew), et non à PTZBot : la demande porte le nom « ffmpeg », et revient après chaque `brew upgrade ffmpeg`. Évolution proposée : un petit utilitaire signé dans PTZBot remplace les deux ffmpeg de capture (AVFoundation pour l'image et le son, VideoToolbox pour le H.264 matériel, AudioToolbox pour l'AAC), et écrit son flux sur sa sortie standard pour go2rtc (`exec:`). ffmpeg ne sert plus qu'à la conversion Opus, sans accès à la caméra. Avant tout, un essai de 5 minutes : un utilitaire rangé dans l'app est-il présenté sous le nom de l'app, ou sous le sien ? Le vrai travail est de retrouver la robustesse du pipeline actuel (son sans dérive, images clés, latence, caméra débranchée, coreaudiod).

## Publication : profil de notarisation vérifié d'avance, et une seconde tentative (13/10/2026)

Le 13/10 à 00:21, la répétition de la 1.1.0 a échoué à la notarisation : `notarytool` a répondu « No Keychain password item found for profile: djoko-notarisation » après dix minutes de tests et de compilation. Le profil n'avait pas été effacé : il est rangé dans le trousseau iCloud, sa lecture a échoué une fois (la synchronisation du trousseau iCloud était en activité à ce moment-là), et elle fonctionnait de nouveau une heure plus tard, sans que rien ait changé. **Cause trouvée** : l'économiseur d'écran démarre après 20 min d'inactivité, avec un verrouillage immédiat. Or le profil n'est lisible que session déverrouillée, et la répétition tournait depuis plus de 20 min sans que Majid touche au Mac. À faire : `publier.sh` lance la publication sous `caffeinate -d` (pas de mise en veille de l'écran, donc ni économiseur ni verrouillage) ; dans `outils/publication.py` : vérifier le profil dès le début (`notarytool history --keychain-profile …`), avant les tests et la compilation ; et si la soumission répond « No Keychain password item found », attendre quelques secondes et réessayer une fois avant d'échouer.

## Test « Ports réels » instable (13/10/2026)

Le test « Ports réels » de `Go2RTCPreparerTests` (PTZBotKit) échoue environ une fois sur dix dans la suite complète, déjà avant le lanceur launchd. Il ouvre de vrais ports : une course avec un autre test, ou un port éphémère repris entre deux étapes, est probable. À rendre déterministe.

## Lanceur launchd de go2rtc : suites de la relecture du 13/10

- **Attente de déchargement hors du MainActor** (I2 b) : quand un travail d'une session tuée vit encore, `LaunchdProcessLauncher` attend son déchargement sur le MainActor, 20 s au plus. Cas rare (le gardien sort dès que PTZBot meurt), mais l'interface se fige pendant ce temps. Correction : décharger pendant la préparation de go2rtc, hors du MainActor.
- **ffmpeg qui ignore SIGTERM** : vérifier, avec un faux go2rtc dont l'enfant ignore SIGTERM, que launchd ne le tue pas à la sortie du gardien ni au `bootout` (`AbandonProcessGroup` vrai), et chercher « stray » dans le journal de launchd.

## Onglet « SDK OBSBOT » : deux boutons pour les outils de développement (13/10/2026)

Quand les outils de développement d'Apple manquent, l'onglet montre deux boutons qui les installent : celui de la ligne d'état (repris de l'ancienne ligne du panneau) et celui du contenu (repris de l'ancienne fenêtre « SDK OBSBOT »). En garder un seul.

