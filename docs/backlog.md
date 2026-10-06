# Pour plus tard

Idées validées par l'usage, pas encore planifiées.

## Sensibilité du joystick

Un réglage dans l'app (par exemple lente, normale, rapide, ou un curseur) qui met à l'échelle les vitesses envoyées à `ptzd`. Le plafond reste celui de `ptzd` (pan 80, tilt 120).

## Authentification des clients de `ptzd`

Aujourd'hui, tout appareil du tailnet peut piloter la nacelle et voir la vidéo. Pistes :

- appairage de l'iPhone avec `ptzd` : une clé générée dans le Secure Enclave de l'iPhone, déverrouillée par Face ID, et un défi signé à chaque connexion (même principe qu'une passkey, sans serveur web) ;
- côté Mac, la liste des clés publiques autorisées, ajoutées par un code d'appairage affiché par `ptzd` ;
- la vidéo (go2rtc) reste hors de ce périmètre : à traiter à part (ACL Tailscale, ou authentification de go2rtc).
