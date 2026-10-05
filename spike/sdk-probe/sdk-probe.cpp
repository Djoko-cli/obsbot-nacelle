// sdk-probe.cpp — SPIKE JETABLE : libdev (SDK OBSBOT) sur la Tiny 2.
// Nécessite le SDK OBSBOT en local dans vendor/obsbot-sdk/ (non versionné, propriétaire).
// Build : clang++ -std=c++17 -I../../vendor/obsbot-sdk/include -L../../vendor/obsbot-sdk/macos/arm64-release -ldev \
//         -Wl,-rpath,../../vendor/obsbot-sdk/macos/arm64-release -o sdk-probe sdk-probe.cpp
// Usage : sdk-probe status | attitude | aimode <mode> [sub]
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dev/devs.hpp>
#include <thread>

using namespace std::chrono;

static double ms(steady_clock::time_point t0) {
  return duration<double, std::milli>(steady_clock::now() - t0).count();
}

static void onDevChanged(std::string sn, bool connected, void *) {
  std::printf("  [callback] %s %s\n", sn.c_str(), connected ? "connecte" : "deconnecte");
}

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  auto t0 = steady_clock::now();
  Devices::get().setDevChangedCallback(onDevChanged, nullptr);
  Devices::get().setEnableMdnsScan(false);

  std::shared_ptr<Device> dev;
  for (int i = 0; i < 50 && !dev; i++) {
    for (auto &d : Devices::get().getDevList())
      if (d->productType() == ObsbotProdTiny2) dev = d;
    if (!dev) std::this_thread::sleep_for(milliseconds(100));
  }
  if (!dev) { std::printf("Tiny 2 introuvable apres %.0f ms\n", ms(t0)); return 1; }
  std::printf("Tiny 2 trouvee en %.0f ms : %s, firmware %s, mode %d\n", ms(t0), dev->devName().c_str(),
              dev->devVersion().c_str(), (int)dev->devMode());

  int rc = 0;
  if (!std::strcmp(argv[1], "status")) {
    Device::CameraStatus st;
    std::memset(&st, 0, sizeof st);
    rc = dev->cameraGetCameraStatusU(st);
    std::printf("cameraGetCameraStatusU=%d ai_mode=%d ai_sub_mode=%d\n", rc, st.tiny.ai_mode, st.tiny.ai_sub_mode);
  } else if (!std::strcmp(argv[1], "attitude")) {
    float xyz[3] = {0, 0, 0};
    rc = dev->gimbalGetAttitudeInfoR(xyz);
    std::printf("gimbalGetAttitudeInfoR=%d roll=%.1f pitch=%.1f pan=%.1f\n", rc, xyz[0], xyz[1], xyz[2]);
  } else if (!std::strcmp(argv[1], "aimode") && argc >= 3) {
    int mode = std::atoi(argv[2]), sub = argc >= 4 ? std::atoi(argv[3]) : 0;
    rc = dev->cameraSetAiModeU((Device::AiWorkModeType)mode, sub);
    std::printf("cameraSetAiModeU(%d,%d)=%d\n", mode, sub, rc);
  }
  auto tc = steady_clock::now();
  Devices::get().close();
  std::printf("total %.0f ms (close %.0f ms)\n", ms(t0), ms(tc));
  return rc == RM_RET_OK ? 0 : 1;
}
