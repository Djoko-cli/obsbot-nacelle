# Pour plus tard

Idées validées par l'usage, pas encore planifiées.

## Sensibilité du joystick

Un réglage dans l'app (par exemple lente, normale, rapide, ou un curseur) qui met à l'échelle les vitesses envoyées à `ptzd`. Le plafond reste celui de `ptzd` (pan 80, tilt 120).

## Vidéo plus légère hors de la maison

En 4G, quand Tailscale passe par un relais (DERP), le flux 1080p à 4 Mbit/s saccade. Pistes : un second flux go2rtc en 720p ou à débit réduit pour le chemin Tailscale ; côté box, rediriger le port UDP 41641 vers le Mac pour que Tailscale trouve un chemin direct.

## Une seule adresse pour le Mac

Ne plus saisir le nom Tailscale : l'app pourrait retenir l'adresse Tailscale du Mac reçue à l'appairage, ou joindre l'IP locale du Mac en 4G par le routage de sous-réseau de Tailscale (à vérifier : comment ce trafic arrive à `ptzd`, et TLS côté app pour cette adresse).
