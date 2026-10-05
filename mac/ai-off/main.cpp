// obsbot-ai-off : coupe le suivi IA de la Tiny 2, puis se termine (spec § 6.9).
// Codes de sortie : 0 = suivi coupé, 1 = caméra introuvable, 2 = erreur du SDK.
// Lancé par ptzd à chaque prise en main ; le SDK ne reste jamais chargé en permanence.
#include <chrono>
#include <cstdio>
#include <dev/devs.hpp>
#include <thread>
#include <unistd.h>

int main() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);

    std::shared_ptr<Device> tiny2;
    // 10 s au plus (amendement A3) : quand la vidéo démarre en même temps, l'initialisation
    // de la caméra par le SDK est plus lente (constaté le 2026-10-05).
    for (int attempt = 0; attempt < 100 && !tiny2; ++attempt) {
        for (auto &device : Devices::get().getDevList()) {
            if (device->productType() == ObsbotProdTiny2) {
                tiny2 = device;
            }
        }
        if (!tiny2) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    if (!tiny2) {
        // Le SDK peut encore initialiser la caméra dans son propre fil : le refermer
        // maintenant provoque un arrêt brutal (libc++abi). On quitte sans destructeurs ;
        // le système libère l'accès USB.
        std::fprintf(stderr, "obsbot-ai-off : Tiny 2 introuvable après 10 s\n");
        std::fflush(stderr);
        _exit(1);
    }

    int32_t result = tiny2->cameraSetAiModeU(Device::AiWorkModeNone, 0);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai-off : cameraSetAiModeU a renvoyé %d\n", result);
        return 2;
    }
    std::printf("obsbot-ai-off : suivi IA coupé\n");
    return 0;
}
