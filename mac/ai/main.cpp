// obsbot-ai on|off : allume (suivi d'une personne) ou coupe le suivi IA de la Tiny 2, puis se termine
// (spec § 6.9, spec app Mac § 7.5). Codes de sortie : 0 = fait, 1 = caméra introuvable, 2 = erreur du SDK,
// 3 = argument manquant ou inconnu. Lancé par ptzd ; le SDK ne reste jamais chargé en permanence.
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dev/devs.hpp>
#include <thread>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2 || (std::strcmp(argv[1], "on") != 0 && std::strcmp(argv[1], "off") != 0)) {
        std::fprintf(stderr, "usage : obsbot-ai on|off\n");
        return 3;
    }
    const bool on = std::strcmp(argv[1], "on") == 0;

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
        std::fprintf(stderr, "obsbot-ai : Tiny 2 introuvable après 10 s\n");
        std::fflush(stderr);
        _exit(1);
    }

    int32_t result = on ? tiny2->cameraSetAiModeU(Device::AiWorkModeHuman, Device::AiSubModeNormal)
                        : tiny2->cameraSetAiModeU(Device::AiWorkModeNone, 0);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : cameraSetAiModeU a renvoyé %d\n", result);
        return 2;
    }
    std::printf("obsbot-ai : suivi IA %s\n", on ? "allumé" : "coupé");
    return 0;
}
