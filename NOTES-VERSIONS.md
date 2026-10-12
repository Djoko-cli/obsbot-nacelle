# Release notes · Notes de version

PTZBot for Mac. Each section has an **English** block, then a **Français** block; the same notes go to the GitHub
release and to the update window.

PTZBot pour Mac. Chaque section a un bloc **English**, puis un bloc **Français** ; les mêmes notes servent à la
version GitHub et à la fenêtre de mise à jour.

## 1.0.7

**English**

- PTZBot is now signed with an Apple Developer ID and notarized by Apple: a freshly downloaded PTZBot opens without
  "Open Anyway". When updating from an earlier version, macOS says once that the app differs from the versions opened
  before and asks whether to open it: choose "Open Anyway". It may also ask again for access to the local network, and
  you may need to turn "Open at login" on again.
- The project moves to github.com/Djoko-cli/ptzbot; old links redirect there.
- Talkback: an update no longer turns Talkback on by itself when you had turned it off.

**Français**

- PTZBot est désormais signé avec un Developer ID d'Apple et notarisé par Apple : un PTZBot fraîchement téléchargé
  s'ouvre sans « Ouvrir quand même ». Depuis une version précédente, macOS dit une seule fois que l'app diffère des
  versions ouvertes jusque-là et demande s'il faut l'ouvrir : choisissez « Ouvrir quand même ». Il peut aussi
  redemander l'accès au réseau local, et il faudra peut-être réactiver « Ouvrir à la connexion ».
- Le projet passe à github.com/Djoko-cli/ptzbot ; les anciens liens y redirigent.
- Talkback : une mise à jour ne rallume plus Talkback de lui-même quand vous l'aviez éteint.

## 1.0.6

**English**

- Fixes an error that could appear in red under Talkback at each launch after updating from 1.0.4 ("Requestor lacks
  required entitlement"). Talkback itself kept working; the message no longer appears.

**Français**

- Corrige une erreur qui pouvait s'afficher en rouge sous Talkback à chaque lancement après une mise à jour depuis
  la 1.0.4 (« Requestor lacks required entitlement »). Talkback fonctionnait malgré tout ; le message n'apparaît plus.

## 1.0.5

**English**

- Talkback is now installed as a classic background agent (`~/Library/LaunchAgents`) instead of a login item
  registered with macOS. Updates no longer stop Talkback: after an update, PTZBot restarts `talkd` with the new
  version by itself. If Talkback was on, it stays on; nothing to do on your side.
- Talkback can no longer be turned on while PTZBot runs from a temporary location (Downloads or the disk image): move
  PTZBot to the Applications folder first.
- If you delete PTZBot while Talkback is on, see the README to remove the agent.

**Français**

- Talkback est désormais installé comme agent d'arrière-plan classique (`~/Library/LaunchAgents`) au lieu d'un
  élément d'ouverture inscrit auprès de macOS. Les mises à jour n'arrêtent plus Talkback : après une mise à jour,
  PTZBot relance de lui-même `talkd` dans sa nouvelle version. Si Talkback était allumé, il le reste ; rien à faire
  de votre côté.
- Talkback ne peut plus être allumé quand PTZBot tourne depuis un emplacement temporaire (Téléchargements ou image
  disque) : déplacez d'abord PTZBot dans le dossier Applications.
- Si vous supprimez PTZBot avec Talkback allumé, voyez le README pour retirer l'agent.

## 1.0.4

**English**

- The Talkback switch reacts at once: "Starting…" or "Stopping…" shows immediately while macOS registers the agent,
  and the panel no longer freezes.
- In the panel, "Playing" appears and disappears as soon as someone speaks. The talk button of the PTZBot iOS app
  follows Talkback being turned on or off within a fraction of a second.
- If macOS refuses to start Talkback right after it is turned on or after an update, PTZBot now registers it again by
  itself after a few seconds: no need to turn it off and on again.

**Français**

- L'interrupteur Talkback réagit tout de suite : « Démarrage… » ou « Arrêt… » s'affiche aussitôt pendant que macOS
  inscrit l'agent, et le panneau ne se fige plus.
- Dans le panneau, « En lecture » apparaît et disparaît dès qu'on parle. Le bouton pour parler de l'app PTZBot iOS
  suit l'allumage ou l'extinction de Talkback en une fraction de seconde.
- Si macOS refuse de lancer Talkback juste après son allumage ou après une mise à jour, PTZBot le réinscrit de
  lui-même au bout de quelques secondes : plus besoin de l'éteindre puis de le rallumer.

## 1.0.3

**English**

- Talk from the iPhone: with the updated PTZBot iOS app, hold the microphone button to speak through the Mac's
  built-in speakers, at home or away. PTZBot passes the voice to Talkback, which must be on.
- After this update, PTZBot re-registers the Talkback agent by itself at first launch: macOS no longer refuses the
  new version of `talkd`. Nothing to do on your side.

**Français**

- Parler depuis l'iPhone : avec l'app PTZBot iOS à jour, maintenez le bouton micro pour parler par les haut-parleurs
  intégrés du Mac, à la maison ou à distance. PTZBot transmet la voix à Talkback, qui doit être allumé.
- Après cette mise à jour, PTZBot réinscrit de lui-même l'agent Talkback au premier lancement : macOS ne refuse plus
  la nouvelle version de `talkd`. Rien à faire de votre côté.

## 1.0.2

**English**

- Talkback: the microphone button of the camera in the Home app now plays your voice on the Mac's built-in
  speakers, even when PTZBot is closed. Turn on "Talkback" in the panel, give your Homebridge host's address in
  `~/Library/Application Support/ObsbotNacelle/talkd.json` (see the README), then add the Homebridge line given
  there. While someone speaks, the speakers are raised to at least 30 % (or unmuted), then put back. Only your
  Homebridge host and the Mac itself are accepted; no microphone is opened and no sound is recorded.

**Français**

- Talkback : le bouton micro de la caméra dans l'app Maison fait désormais sortir votre voix par les haut-parleurs
  intégrés du Mac, même PTZBot fermé. Allumez « Talkback » dans le panneau, indiquez l'adresse de votre hôte Homebridge
  dans `~/Library/Application Support/ObsbotNacelle/talkd.json` (voir le README), puis ajoutez la ligne Homebridge
  donnée dans le README. Pendant la parole, les haut-parleurs sont remontés à 30 % au moins (ou sortis de la sourdine),
  puis remis comme avant. Seuls votre hôte Homebridge et le Mac lui-même sont acceptés ; aucun micro n'est ouvert
  et aucun son n'est enregistré.

## 1.0.1

**English**

- Instant AI tracking: once the OBSBOT SDK is loaded, turning tracking on or off takes effect within a few
  milliseconds instead of about four seconds. PTZBot keeps `obsbot-ai` running while an iPhone or the Mac is
  controlling the camera, and stops it after ten minutes without activity. The first order after opening the app
  can still take a few seconds, the time for the SDK to load; after that, it is immediate. PTZBot recompiles
  `obsbot-ai` by itself after this update, if the SDK is installed.
- The app now has an icon: the photo of the camera.

**Français**

- Suivi IA instantané : une fois le SDK OBSBOT chargé, allumer ou couper le suivi prend effet en quelques
  millisecondes, au lieu d'environ quatre secondes. PTZBot garde `obsbot-ai` en marche tant qu'un iPhone ou le Mac
  pilote la caméra, et l'arrête après dix minutes sans activité. Le premier ordre après l'ouverture de l'app peut
  encore prendre quelques secondes, le temps que le SDK se charge ; ensuite, c'est immédiat. PTZBot recompile
  `obsbot-ai` seul après cette mise à jour, si le SDK est installé.
- L'app a désormais une icône : la photo de la caméra.

## 1.0.0

**English**

- PTZBot for Mac now comes as a disk image: drag it into Applications. The first time, macOS asks you to confirm
  with "Open Anyway" in System Settings › Privacy & Security.
- Automatic updates with Sparkle, signed with an Ed25519 key: PTZBot checks at launch and every 24 hours, and
  installs when you quit or with "Install and Relaunch". "Check for Updates…" and "Settings…" are in the panel.
- The app speaks English and French, including the errors reported by ptzd. By default it follows macOS; the
  "Language" setting in Settings (Automatic, Français, English) lets you choose.
- obsbot-ai is no longer shipped: PTZBot compiles it on your Mac from the OBSBOT SDK you provide, with Apple's
  developer tools. If you installed the SDK with an earlier build, reinstall it from its archive or folder.

**Français**

- PTZBot pour Mac s'installe désormais depuis une image disque : glissez-le dans Applications. La première fois,
  macOS demande de confirmer par « Ouvrir quand même » dans Réglages Système › Confidentialité et sécurité.
- Mises à jour automatiques par Sparkle, signées par une clé Ed25519 : PTZBot cherche au lancement puis toutes les
  24 heures, et installe à la fermeture ou par « Installer et relancer ». « Rechercher les mises à jour… » et
  « Réglages… » sont dans le panneau.
- L'app parle français et anglais, erreurs de ptzd comprises. Par défaut, elle suit macOS ; le réglage « Langue »
  des Réglages (Automatique, Français, English) permet de choisir.
- obsbot-ai n'est plus livré : PTZBot le compile sur votre Mac à partir du SDK OBSBOT que vous fournissez, avec les
  outils de développement d'Apple. Si vous aviez installé le SDK avec une version précédente, réinstallez-le depuis
  son archive ou son dossier.
