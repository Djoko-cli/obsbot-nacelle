# Pour plus tard

Idées validées par l'usage, pas encore planifiées.

## Sensibilité du joystick

Un réglage dans l'app (par exemple lente, normale, rapide, ou un curseur) qui met à l'échelle les vitesses envoyées à `ptzd`. Le plafond reste celui de `ptzd` (pan 80, tilt 120).


## Une seule adresse pour le Mac

Ne plus saisir le nom Tailscale : l'app pourrait retenir l'adresse Tailscale du Mac reçue à l'appairage, ou joindre l'IP locale du Mac en 4G par le routage de sous-réseau de Tailscale (à vérifier : comment ce trafic arrive à `ptzd`, et TLS côté app pour cette adresse).

## Enregistrer la vidéo et le son

Un bouton d'enregistrement (rec) dans l'app iOS, à côté du son et de la vie privée : il enregistre la vidéo et le son reçus jusqu'à ce qu'on l'arrête. À trancher : où ranger le fichier (Photos ou Fichiers), le format (MP4 en H.264 et AAC, sans réencoder si possible), l'indication visible pendant l'enregistrement, et l'arrêt automatique à l'entrée en vie privée, à la coupure de la connexion et au passage en arrière-plan.

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
