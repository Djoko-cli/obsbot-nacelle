// uvc-probe.c — SPIKE JETABLE : commandes UVC de la OBSBOT Tiny 2 via IOKit.
// Gardé comme trace du test de faisabilité (docs/spike/2026-10-05-faisabilite.md).
// Ce n'est pas le code du service : ptzd sera réécrit proprement, avec ses tests.
// Build : clang -O1 -o uvc-probe uvc-probe.c -framework IOKit -framework CoreFoundation
// Usage : uvc-probe info | get | pt <pan°> <tilt°> | zoom <v> | ptrel <pdir> <pspd> <tdir> <tspd> | zrel <dir> <spd>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VID 0x3564
#define PID 0xFEF8

#define GET_CUR 0x81
#define GET_MIN 0x82
#define GET_MAX 0x83
#define GET_RES 0x84
#define GET_LEN 0x85
#define GET_INFO 0x86
#define GET_DEF 0x87
#define SET_CUR 0x01

#define CT_ZOOM_ABS 0x0B
#define CT_ZOOM_REL 0x0C
#define CT_PT_ABS 0x0D
#define CT_PT_REL 0x0E
#define CT_PRIVACY 0x11

static IOUSBDeviceInterface245 **dev;
static int vcIf = -1, ctId = -1;
static uint32_t ctControls;

static IOReturn req(uint8_t type, uint8_t r, uint16_t val, uint16_t idx, void *buf, uint16_t len, uint32_t *done) {
  IOUSBDevRequestTO rq = {0};
  rq.bmRequestType = type;
  rq.bRequest = r;
  rq.wValue = val;
  rq.wIndex = idx;
  rq.wLength = len;
  rq.pData = buf;
  rq.noDataTimeout = 1000;
  rq.completionTimeout = 1000;
  IOReturn kr = (*dev)->DeviceRequestTO(dev, &rq);
  if (done) *done = rq.wLenDone;
  return kr;
}

static IOReturn ctGet(uint8_t r, uint8_t sel, void *buf, uint16_t len) {
  return req(0xA1, r, sel << 8, (ctId << 8) | vcIf, buf, len, NULL);
}

static IOReturn ctSet(uint8_t sel, void *buf, uint16_t len) {
  return req(0x21, SET_CUR, sel << 8, (ctId << 8) | vcIf, buf, len, NULL);
}

static int openDevice(void) {
  CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
  int v = VID, p = PID;
  CFDictionarySetValue(m, CFSTR("idVendor"), CFNumberCreate(NULL, kCFNumberIntType, &v));
  CFDictionarySetValue(m, CFSTR("idProduct"), CFNumberCreate(NULL, kCFNumberIntType, &p));
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
  if (!svc) { fprintf(stderr, "Tiny 2 introuvable (VID %04x PID %04x)\n", VID, PID); return -1; }
  IOCFPlugInInterface **plug = NULL;
  SInt32 score;
  IOReturn kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
  IOObjectRelease(svc);
  if (kr || !plug) { fprintf(stderr, "plugin: 0x%08x\n", kr); return -1; }
  (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID245), (LPVOID *)&dev);
  (*plug)->Release(plug);
  if (!dev) { fprintf(stderr, "QueryInterface a échoué\n"); return -1; }
  return 0;
}

static const char *ctBitNames[] = {"Scanning", "AE mode", "AE prio", "Exposure abs", "Exposure rel", "Focus abs", "Focus rel", "Iris abs", "Iris rel", "Zoom abs", "Zoom rel", "PanTilt abs", "PanTilt rel", "Roll abs", "Roll rel", "-", "-", "Focus auto", "Privacy", "Focus simple", "Window", "ROI"};

static int parseConfig(int verbose) {
  uint8_t hdr[9];
  uint32_t done = 0;
  IOReturn kr = req(0x80, 6, 0x0200, 0, hdr, 9, &done);
  if (kr) { fprintf(stderr, "GET_DESCRIPTOR(config): 0x%08x\n", kr); return -1; }
  uint16_t total = hdr[2] | hdr[3] << 8;
  uint8_t *b = malloc(total);
  kr = req(0x80, 6, 0x0200, 0, b, total, &done);
  if (kr) { fprintf(stderr, "GET_DESCRIPTOR(full): 0x%08x\n", kr); return -1; }
  int curIf = -1, curClass = -1, curSub = -1;
  for (int i = 0; i + 2 <= (int)done && b[i] > 0; i += b[i]) {
    uint8_t len = b[i], type = b[i + 1];
    if (type == 4) {
      curIf = b[i + 2]; curClass = b[i + 5]; curSub = b[i + 6];
      if (verbose && b[i + 3] == 0) printf("Interface %d : classe %02x sous-classe %02x\n", curIf, curClass, curSub);
      if (curClass == 0x0E && curSub == 1) vcIf = curIf;
    } else if (type == 0x24 && curClass == 0x0E && curSub == 1) {
      uint8_t st = b[i + 2];
      if (st == 2 && (b[i + 4] | b[i + 5] << 8) == 0x0201) {
        ctId = b[i + 3];
        int sz = b[i + 14];
        ctControls = 0;
        for (int k = 0; k < sz && k < 4; k++) ctControls |= (uint32_t)b[i + 15 + k] << (8 * k);
        if (verbose) {
          printf("Camera Terminal id=%d bmControls=0x%06x :", ctId, ctControls);
          for (int k = 0; k < 22; k++) if (ctControls & (1u << k)) printf(" [%s]", ctBitNames[k]);
          printf("\n");
        }
      } else if (st == 5 && verbose) {
        printf("Processing Unit id=%d\n", b[i + 3]);
      } else if (st == 6 && verbose) {
        printf("Extension Unit id=%d controles=%d GUID=", b[i + 3], b[i + 20]);
        for (int k = 0; k < 16; k++) printf("%02x", b[i + 4 + k]);
        printf("\n");
      }
    }
    (void)len;
  }
  free(b);
  if (vcIf < 0 || ctId < 0) { fprintf(stderr, "VideoControl ou Camera Terminal introuvable\n"); return -1; }
  return 0;
}

static void dumpPT(const char *label, uint8_t r) {
  uint8_t d[8] = {0};
  IOReturn kr = ctGet(r, CT_PT_ABS, d, 8);
  if (kr) { printf("  PanTilt %-4s : erreur 0x%08x\n", label, kr); return; }
  int32_t pan, tilt;
  memcpy(&pan, d, 4);
  memcpy(&tilt, d + 4, 4);
  printf("  PanTilt %-4s : pan=%d (%.2f°) tilt=%d (%.2f°)\n", label, pan, pan / 3600.0, tilt, tilt / 3600.0);
}

static void dumpZoom(const char *label, uint8_t r) {
  uint8_t d[2] = {0};
  IOReturn kr = ctGet(r, CT_ZOOM_ABS, d, 2);
  if (kr) { printf("  Zoom    %-4s : erreur 0x%08x\n", label, kr); return; }
  printf("  Zoom    %-4s : %u\n", label, d[0] | d[1] << 8);
}

static void dumpRel(void) {
  uint8_t d[4] = {0};
  const char *lbl[] = {"MIN", "MAX", "RES", "DEF"};
  uint8_t rr[] = {GET_MIN, GET_MAX, GET_RES, GET_DEF};
  for (int k = 0; k < 4; k++) {
    memset(d, 0, 4);
    IOReturn kr = ctGet(rr[k], CT_PT_REL, d, 4);
    if (kr) printf("  PTrel   %-4s : erreur 0x%08x\n", lbl[k], kr);
    else printf("  PTrel   %-4s : pan=%d spd=%u tilt=%d spd=%u\n", lbl[k], (int8_t)d[0], d[1], (int8_t)d[2], d[3]);
  }
  for (int k = 0; k < 4; k++) {
    uint8_t z[3] = {0};
    IOReturn kr = ctGet(rr[k], CT_ZOOM_REL, z, 3);
    if (kr) printf("  Zrel    %-4s : erreur 0x%08x\n", lbl[k], kr);
    else printf("  Zrel    %-4s : zoom=%d digital=%u spd=%u\n", lbl[k], (int8_t)z[0], z[1], z[2]);
  }
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s info|get|pt|zoom|ptrel|zrel ...\n", argv[0]); return 2; }
  if (openDevice()) return 1;
  int verbose = !strcmp(argv[1], "info");
  if (parseConfig(verbose)) return 1;

  if (!strcmp(argv[1], "info")) {
    const char *lbl[] = {"MIN", "MAX", "RES", "DEF", "CUR"};
    uint8_t rr[] = {GET_MIN, GET_MAX, GET_RES, GET_DEF, GET_CUR};
    for (int k = 0; k < 5; k++) dumpPT(lbl[k], rr[k]);
    for (int k = 0; k < 5; k++) dumpZoom(lbl[k], rr[k]);
    dumpRel();
    uint8_t info = 0;
    IOReturn kr = ctGet(GET_INFO, CT_PRIVACY, &info, 1);
    printf("  Privacy INFO : %s 0x%02x\n", kr ? "erreur" : "ok", kr ? kr : info);
  } else if (!strcmp(argv[1], "get")) {
    dumpPT("CUR", GET_CUR);
    dumpZoom("CUR", GET_CUR);
  } else if (!strcmp(argv[1], "pt") && argc == 4) {
    int32_t v[2] = {(int32_t)(atof(argv[2]) * 3600), (int32_t)(atof(argv[3]) * 3600)};
    IOReturn kr = ctSet(CT_PT_ABS, v, 8);
    printf("SET PanTilt abs pan=%d tilt=%d : 0x%08x\n", v[0], v[1], kr);
  } else if (!strcmp(argv[1], "zoom") && argc == 3) {
    uint16_t z = (uint16_t)atoi(argv[2]);
    IOReturn kr = ctSet(CT_ZOOM_ABS, &z, 2);
    printf("SET Zoom abs %u : 0x%08x\n", z, kr);
  } else if (!strcmp(argv[1], "ptrel") && argc == 6) {
    uint8_t d[4] = {(uint8_t)(int8_t)atoi(argv[2]), (uint8_t)atoi(argv[3]), (uint8_t)(int8_t)atoi(argv[4]), (uint8_t)atoi(argv[5])};
    IOReturn kr = ctSet(CT_PT_REL, d, 4);
    printf("SET PanTilt rel %d/%u %d/%u : 0x%08x\n", (int8_t)d[0], d[1], (int8_t)d[2], d[3], kr);
  } else if (!strcmp(argv[1], "zrel") && argc == 4) {
    uint8_t d[3] = {(uint8_t)(int8_t)atoi(argv[2]), 0, (uint8_t)atoi(argv[3])};
    IOReturn kr = ctSet(CT_ZOOM_REL, d, 3);
    printf("SET Zoom rel %d spd=%u : 0x%08x\n", (int8_t)d[0], d[2], kr);
  } else {
    fprintf(stderr, "commande inconnue\n");
    return 2;
  }
  return 0;
}
