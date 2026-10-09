# Enregistrer la vidéo et le son dans l'app iOS : conception

Date : 09/10/2026. Choix validés par Majid en conversation. Voie courte : prototype, relecture, banc, report sur
`main`, relecture finale.

## 1. Objectif

Un bouton rec dans l'app iOS PTZBot. Il enregistre la vidéo et le son reçus de la caméra jusqu'à ce qu'on l'arrête,
puis range la vidéo dans Photos. Ce changement ne touche que l'app iOS : ni `ptzd`, ni l'app Mac, ni go2rtc.

## 2. Choix de Majid

| Question | Choix |
|---|---|
| Qui enregistre | **L'iPhone**, à partir du flux WebRTC qu'il reçoit déjà (pas le Mac) |
| Où va le fichier | **Photos**, avec l'autorisation « ajout seulement » |
| Son coupé dans l'app | **Le son est quand même enregistré** : le haut-parleur reste muet, la piste audio non |
| Vie privée | **Le bouton rec est grisé en vie privée**, et l'entrée en vie privée arrête l'enregistrement et le sauve |

Arrêts imposés par iOS ou le réseau : le passage en arrière-plan (ou le verrouillage) et la coupure de connexion
arrêtent l'enregistrement et sauvent ce qui a été filmé. Rien ne reprend seul à la reconnexion.

## 3. Interface

- **Place :** dans la rangée du haut à droite, qui devient son, suivi IA, **rec**, vie privée. Même cercle de
  44 points que les autres boutons.
- **Au repos :** icône `record.circle`, blanche sur fond translucide (`.ultraThinMaterial`).
- **Pendant l'enregistrement :**
  - l'icône devient `stop.fill` sur fond rouge ;
  - un badge « ● 00:42 » s'affiche en haut au centre de la vidéo, avec un point rouge qui pulse et un chronomètre
    en chiffres de largeur fixe (`monospacedDigit`) ;
  - ces deux signes restent visibles en portrait, en paysage et en plein écran.
- **Bouton grisé (opacité 0,4, désactivé) :**
  - en vie privée ;
  - tant qu'aucune image vidéo n'a été reçue ;
  - quand l'accès à Photos est refusé. Dans ce cas, le bouton reste touchable et explique comment l'autoriser.
- **Premier appui :** iOS demande l'accès « Ajouter à Photos ». En cas de refus, rien ne démarre et un message
  s'affiche.
- **À l'arrêt :**
  - une vibration légère (`sensoryFeedback(.success)`) ;
  - un bandeau bref : « Vidéo enregistrée dans Photos (0:42) ».
- **En cas d'échec :** un bandeau d'erreur qui donne la raison (section 6).
- **Textes :** au « vous », en français. La traduction de l'app iOS vient plus tard et les reprendra.
- **Accessibilité :** libellés « Enregistrer » et « Arrêter l'enregistrement ». Le badge annonce
  « Enregistrement en cours, 42 secondes ».

## 4. Architecture

Trois pièces, chacune testable seule, et le pilotage dans `AppModel`.

### 4.1 `ClipRecorder` (nouveau, `ios/Nacelle/Recording/`)

Il écrit un MP4 avec `AVAssetWriter`, dans le dossier temporaire de l'app (`PTZBot-<date>.mp4`).

- **Vidéo :** H.264 encodé par la puce de l'iPhone. `AVAssetWriterInput` reçoit
  `AVVideoCodecKey: .h264`, la largeur et la hauteur de la première image, un débit moyen d'environ
  6 Mbit/s pour du 1080p (proportionnel aux pixels, avec 2 Mbit/s au minimum) et
  `expectsMediaDataInRealTime = true`.
- **Son :** AAC, 48 kHz, au nombre de canaux reçu, 128 kbit/s.
- **Horloge :** les deux pistes sont horodatées avec l'heure de réception sur l'iPhone (horloge de l'hôte,
  `CMClockGetHostTimeClock`). La session commence à la première image vidéo reçue après l'appui. Le son reçu avant
  cette image est ignoré.
- **Changement de résolution en cours d'enregistrement :** le MP4 garde la taille du début. Les images d'une autre
  taille sont remises à l'échelle avec `VTPixelTransferSession`, sans coupure.
- **Rotation :** la rotation de l'image WebRTC (`RTCVideoFrame.rotation`) devient la transformation de la piste.
- **Images I420 :** si une image n'est pas un `CVPixelBuffer` (`RTCI420Buffer`), elle est convertie en NV12
  avant l'écriture.
- **Images en retard :** si l'entrée vidéo n'est pas prête (`isReadyForMoreMediaData` faux), l'image est sautée.
  Il ne faut jamais bloquer le fil de rendu WebRTC.
- **Interface :** `start(url:)`, `append(video:at:)`, `append(audio:at:)`, puis
  `finish() async throws -> RecordingResult` (URL et durée). Tout passe par une file série privée.

### 4.2 Prises sur le flux existant

- **Vidéo :** `RecordingRenderer`, un `RTCVideoRenderer` branché sur la piste vidéo de `VideoSession` à côté de la
  vue, seulement pendant un enregistrement. Il transmet chaque `RTCVideoFrame` au `ClipRecorder`.
- **Son :** `PlayoutAudioDevice` reçoit déjà le PCM décodé pour le jouer.
  - Pendant un enregistrement, il en copie une version dans un **tampon circulaire sans verrou**, écrit par le fil
    audio temps réel et lu par la file du `ClipRecorder`. Taille : 2 s de son.
  - Si le tampon est plein, les plus anciens échantillons sont perdus et un compteur l'enregistre. Le fil temps
    réel n'attend jamais.
- **Son coupé :** pendant un enregistrement, la piste audio reste active (`isEnabled = true`). Le bouton son ne
  commande alors plus que la sortie : `PlayoutAudioDevice` envoie du silence au haut-parleur, mais copie quand même
  le vrai son dans le tampon. Après l'enregistrement, la piste retrouve l'état du bouton son.

### 4.3 Rangement dans Photos

- `PhotoLibrarySaver`, derrière un protocole pour les tests.
- Autorisation : `PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
- Ajout : `PHAssetCreationRequest`, puis effacement du fichier temporaire.
- Si l'ajout échoue, le fichier temporaire est gardé et le bandeau propose « Réessayer ».
- Au lancement de l'app, les fichiers temporaires de plus de 7 jours sont effacés.
- Info.plist : `NSPhotoLibraryAddUsageDescription` = « Pour ranger dans Photos les vidéos que vous enregistrez. »

### 4.4 Pilotage dans `AppModel`

- **État :** `recording` peut valoir `idle`, `recording(since:)` ou `saving`. On y ajoute `recordToggleEnabled`
  et `photoAccessDenied`.
- **Arrêts automatiques, avec sauvegarde :**
  - entrée en vie privée ;
  - fin de la connexion à `ptzd` ou de la session vidéo ;
  - passage en arrière-plan (`scenePhase`) ;
  - espace disque bas.
- **Arrière-plan :** `UIApplication.beginBackgroundTask` couvre la finalisation et l'ajout à Photos. Si iOS reprend
  la main avant la fin, le fichier temporaire reste et sera proposé au retour, avec « Réessayer ».
- **Espace disque :**
  - au démarrage, il faut au moins 500 Mo libres (`volumeAvailableCapacityForImportantUsage`) ;
  - pendant l'enregistrement, une vérification toutes les 10 s arrête et sauve s'il reste moins de 200 Mo.
- **Pas de durée maximale :** l'espace disque sert de limite.

## 5. Ce qui ne change pas

- Le protocole entre l'iPhone et `ptzd`, ainsi que `ptzd` lui-même.
- L'app Mac, go2rtc et sa configuration.
- La lecture vidéo et son dans l'app, hors enregistrement.

## 6. Erreurs (bandeau, au « vous »)

| Cas | Comportement | Texte |
|---|---|---|
| Accès à Photos refusé | Rien ne démarre | « L'accès à Photos est refusé : autorisez-le dans Réglages › PTZBot › Photos. » |
| Moins de 500 Mo libres au démarrage | Rien ne démarre | « Espace insuffisant sur l'iPhone pour enregistrer. » |
| Moins de 200 Mo en cours | Arrêt, la vidéo est sauvée | « Enregistrement arrêté : espace insuffisant. » puis le bandeau d'arrêt |
| Échec d'écriture du MP4 | Arrêt ; fichier gardé s'il est lisible, effacé sinon | « L'enregistrement a échoué. » |
| Échec de l'ajout à Photos | Fichier gardé, bouton « Réessayer » | « La vidéo n'a pas pu être ajoutée à Photos. » |

## 7. Tests (simulateur, sans caméra)

- **`ClipRecorder` :**
  - images NV12 et I420 de synthèse, plus du PCM de synthèse, écrits dans un vrai MP4 relu avec `AVURLAsset` ;
  - on vérifie : deux pistes, une durée juste à ±0,1 s, l'écart entre le son et la vidéo sous 50 ms, la rotation
    appliquée, un changement de résolution sans coupure, les images sautées sans blocage, et l'absence de son avant
    la première image.
- **Tampon audio :** ordre préservé, aucune perte tant que le tampon n'est pas plein, compteur de pertes quand il
  déborde, et aucune attente côté écriture.
- **`AppModel`** (enregistreur et service Photos simulés) :
  - les arrêts automatiques : vie privée, connexion, arrière-plan, espace disque ;
  - le bouton grisé (vie privée, pas d'image, accès refusé) ;
  - le son enregistré même avec le haut-parleur coupé, et la piste remise dans l'état du bouton son à la fin ;
  - « Réessayer » après un échec de l'ajout à Photos.
- Toutes les attentes ont une limite de temps : pas de boucle d'attente sans fin.

## 8. Banc avec Majid

1. **Wi-Fi :** 30 s d'enregistrement, puis arrêt au bouton. La vidéo est dans Photos, avec l'image et le son
   synchronisés.
2. **Son coupé dans l'app :** l'enregistrement a du son, et le haut-parleur est resté muet.
3. **Vie privée :** l'entrée arrête et sauve, et le bouton reste grisé.
4. **Arrière-plan :** le bouton d'accueil pendant un enregistrement donne une vidéo sauvée.
5. **4G :** 1 min d'enregistrement, puis une coupure de réseau (mode avion). La vidéo est sauvée.
6. **Charge :** 10 min d'enregistrement. Pas de saccade à l'écran, une chauffe raisonnable, et une taille de fichier
   proche de l'estimation (environ 45 Mo par minute en 1080p).

## 9. Amendements (prototype)

Écarts à la spec constatés au prototype et acceptés. Ils remplacent le texte des sections citées.

1. **§ 4.2, tampon audio plein : le bloc est refusé.** Quand le tampon est plein, le fil temps réel refuse le
   nouveau bloc (et compte la perte) au lieu d'effacer les plus anciens. Effacer depuis le producteur casserait le
   contrat à un producteur et un consommateur, et ne se ferait que par compare-and-swap, interdit sur le fil
   temps réel. Pour un fichier, l'effet est le même : un trou de même durée, comblé par du silence d'après les
   heures.
2. **§ 3, place du badge.** En portrait, le badge « ● 00:42 » est sous la rangée des boutons, faute de place dans
   elle. En paysage, il est dans la rangée, au centre (avec le bandeau à côté s'il y en a un), à la demande de Majid
   au banc. Il reste visible dans toutes les orientations.
3. **§ 6, bandeau composé quand l'espace manque.** L'arrêt sur manque d'espace affiche un seul bandeau composé :
   « Enregistrement arrêté : espace insuffisant. Vidéo enregistrée dans Photos (0:42) ». Deux bandeaux à moins
   d'une seconde d'écart seraient illisibles.
4. **§ 3, bandeau sur sa propre ligne en portrait.** En portrait (hauteur « regular »), le bandeau passe sur une
   ligne centrée, sous la rangée du haut et au-dessus du badge : la rangée de cinq boutons ne laisse que 60 à
   115 points au texte. En paysage, il reste dans la rangée.
5. **§ 4.1, fragments MP4 toutes les 2 s.** Le rédacteur écrit un fragment complet toutes les 2 s
   (`movieFragmentInterval`). Si la finalisation échoue (iOS peut invalider l'encodeur en arrière-plan) ou si l'app
   meurt, le fichier reste lisible jusqu'au dernier fragment au lieu d'être perdu en entier. Un fragment ne se
   ferme que lorsque toutes les pistes ont avancé : la piste son doit donc recevoir des blocs (de la parole, du
   silence du périphérique ou du silence de comblement).
6. **§ 6, arrêt sur échec d'écriture.** Dès la première erreur d'écriture, l'enregistreur prévient l'app, qui
   arrête l'enregistrement et traite le fichier comme à un arrêt normal : « L'enregistrement a échoué. » s'affiche
   tout de suite, sans attendre un appui. Cette règle remplace « Échec d'écriture du MP4 » du tableau.
7. **§ 6, finalisation en échec mais fichier lisible : ajouté à Photos.** Si le MP4 se lit malgré l'échec, il est
   ajouté directement à Photos avec le bandeau de réussite (sans durée : « Vidéo enregistrée dans Photos »), après
   « L'enregistrement a échoué. » quand l'échec vient d'une erreur d'écriture en cours de route. Le bandeau
   d'échec ne s'affiche que si le fichier est illisible (il est alors effacé) ou si l'ajout à Photos échoue.
8. **§ 6, bandeau « La vidéo n'a pas pu être ajoutée à Photos. » : bouton de fermeture.** Il garde « Réessayer » et
   reçoit une croix (VoiceOver : « Fermer »). La fermeture masque le bandeau et garde le fichier temporaire, effacé
   au bout de 7 jours comme prévu ; l'état de connexion reprend sa place. Une autre vidéo non ajoutée ramène le
   bandeau.
9. **§ 4.2, trou de son comblé par morceaux.** Le silence qui comble un trou (appel, Siri) est écrit par morceaux
   d'au plus 1 s, jamais en un seul bloc, quelle que soit la durée du trou. Un trou laissé vide serait resserré par
   le MP4 et le son arriverait en avance sur l'image.
10. **§ 3, bouton grisé tant que la vidéo ne joue pas.** Le bouton exige aussi que la connexion vidéo soit en lecture,
    en plus d'une image reçue.
11. **§ 3, mode épuré (demande de Majid au banc).** Un tap sur la vidéo nue masque l'interface en fondu : roue des
    réglages, boutons son, suivi IA et vie privée, joystick, zoom, bandeau d'état, barre d'état d'iOS et indicateur
    d'accueil. Un second tap la rend. Pendant un enregistrement (ou sa sauvegarde), le bouton rec, à sa place, et le
    badge restent ; au repos, rien. Les bandeaux de l'enregistrement (vidéo rangée, échec, vidéo hors de Photos)
    restent affichés. Le mode ne vaut que connecté, la vidéo jouant : à la moindre coupure, l'interface revient avec
    son bandeau, et le mode épuré reprend au retour de la vidéo. Il n'est jamais retenu d'un lancement à l'autre.
