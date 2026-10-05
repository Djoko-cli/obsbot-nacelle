#ifndef CUVC_H
#define CUVC_H

#include <stdint.h>

/// Accès aux commandes UVC d'une caméra USB, sans ouverture exclusive :
/// le pilote vidéo d'Apple et ffmpeg continuent de capturer.
typedef struct cuvc_device cuvc_device;

/// Ouvre la caméra (VID/PID) et repère son Camera Terminal.
/// Renvoie NULL si elle est absente ; *error reçoit alors le code IOKit.
cuvc_device *cuvc_open(uint16_t vendor_id, uint16_t product_id, int32_t *error);

void cuvc_close(cuvc_device *device);

/// Requête de classe sur le Camera Terminal. request vaut 0x01 (SET_CUR)
/// ou 0x81…0x87 (GET_CUR…GET_DEF). Renvoie le code IOKit, 0 en cas de succès.
int32_t cuvc_camera_control(cuvc_device *device, uint8_t request, uint8_t selector,
                            void *data, uint16_t length);

#endif
