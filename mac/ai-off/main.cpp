// obsbot-ai-off : coupe le suivi IA de la Tiny 2, puis se termine (spec § 6.9).
// Codes de sortie : 0 = suivi coupé, 1 = caméra introuvable, 2 = erreur du SDK.
// Lancé par ptzd à chaque prise en main ; le SDK ne reste jamais chargé en permanence.
#include <chrono>
#include <cstdio>
#include <dev/devs.hpp>
#include <thread>

int main() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);

    std::shared_ptr<Device> tiny2;
    for (int attempt = 0; attempt < 50 && !tiny2; ++attempt) {
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
        std::fprintf(stderr, "obsbot-ai-off : Tiny 2 introuvable après 5 s\n");
        Devices::get().close();
        return 1;
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
