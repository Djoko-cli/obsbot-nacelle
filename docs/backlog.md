# Pour plus tard

Idées validées par l'usage, pas encore planifiées.

## Sensibilité du joystick

Un réglage dans l'app (par exemple lente, normale, rapide, ou un curseur) qui met à l'échelle les vitesses envoyées à `ptzd`. Le plafond reste celui de `ptzd` (pan 80, tilt 120).


## Une seule adresse pour le Mac

Ne plus saisir le nom Tailscale : l'app pourrait retenir l'adresse Tailscale du Mac reçue à l'appairage, ou joindre l'IP locale du Mac en 4G par le routage de sous-réseau de Tailscale (à vérifier : comment ce trafic arrive à `ptzd`, et TLS côté app pour cette adresse).

## Enregistrer la vidéo et le son

Un bouton d'enregistrement (rec) dans l'app iOS, à côté du son et de la vie privée : il enregistre la vidéo et le son reçus jusqu'à ce qu'on l'arrête. À trancher : où ranger le fichier (Photos ou Fichiers), le format (MP4 en H.264 et AAC, sans réencoder si possible), l'indication visible pendant l'enregistrement, et l'arrêt automatique à l'entrée en vie privée, à la coupure de la connexion et au passage en arrière-plan.

## Suivi IA instantané (utilitaire résident)

`obsbot-ai serve` garde le SDK OBSBOT chargé pendant qu'un client pilote : un ordre de suivi IA part en quelques millisecondes au lieu de 4,2 s (attente interne du SDK à chaque lancement). Prototypé, relu et essayé au banc le 07/10/2026 sur la branche locale `proto/ai-resident`, puis retiré du service : le SDK utilise AVFoundation et CoreAudio, et un test en cours sur les blocages de coreaudiod doit rester à une seule variable. À activer après la conclusion de ce test, puis à mesurer seul quelques jours, avant d'embarquer go2rtc (sous-projet B3). Ordre décidé le 07/10/2026 : B1 (`ptzd` dans l'app), B2 (distribution), suivi IA instantané dès la fin du test, puis B3.
