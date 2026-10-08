// obsbot-ai on|off : allume (suivi d'une personne) ou coupe le suivi IA de la Tiny 2, puis se termine
// (spec § 6.9, spec app Mac § 7.5). Codes de sortie : 0 = fait, 1 = caméra introuvable, 2 = erreur du SDK,
// 3 = argument manquant ou inconnu. Le mode à un coup sert de repli et de vérification de l'installeur du SDK
// (lancé sans argument, il sort avec le code 3 sans charger le SDK).
// obsbot-ai serve : garde le SDK chargé et lit les ordres `on` ou `off` sur l'entrée, un par ligne ; répond
// sur la sortie par « obsbot-ai: ready », puis « obsbot-ai: ok » ou « obsbot-ai: err <code> » par ordre.
// Se termine quand l'entrée se ferme. Lancé par ptzd, seulement pendant qu'un client pilote.
// En mode serve, la vraie sortie standard est réservée aux réponses : tout ce que le SDK écrit sur la
// sortie standard va vers l'erreur standard (le journal), pour ne jamais se mêler aux réponses.
// En mode serve, un fil surveille aussi le parent : si ptzd meurt pendant que le SDK bloque le fil principal,
// on sort quand même, pour ne jamais laisser un utilitaire orphelin qui garde la caméra.
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dev/devs.hpp>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <thread>
#include <unistd.h>

// 10 s au plus (amendement A3) : quand la vidéo démarre en même temps, l'initialisation
// de la caméra par le SDK est plus lente (constaté le 2026-10-05).
static std::shared_ptr<Device> findTiny2() {
    Devices::get().setDevChangedCallback([](std::string, bool, void *) {}, nullptr);
    Devices::get().setEnableMdnsScan(false);
    for (int attempt = 0; attempt < 100; ++attempt) {
        for (auto &device : Devices::get().getDevList()) {
            if (device->productType() == ObsbotProdTiny2) {
                return device;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return nullptr;
}

static int32_t setTracking(const std::shared_ptr<Device> &tiny2, bool on) {
    return on ? tiny2->cameraSetAiModeU(Device::AiWorkModeHuman, Device::AiSubModeNormal)
              : tiny2->cameraSetAiModeU(Device::AiWorkModeNone, 0);
}

// Le SDK peut encore initialiser la caméra dans son propre fil : le refermer
// maintenant provoque un arrêt brutal (libc++abi). On quitte sans destructeurs ;
// le système libère l'accès USB.
// En mode serve, `replies` reçoit « obsbot-ai: err 1 » ; en mode à un coup (nullptr), seul le code de sortie parle.
[[noreturn]] static void notFound(std::FILE *replies) {
    std::fprintf(stderr, "obsbot-ai : Tiny 2 introuvable après 10 s\n");
    if (replies != nullptr) {
        std::fprintf(replies, "obsbot-ai: err 1\n");
        std::fflush(replies);
    }
    std::fflush(stderr);
    _exit(1);
}

static void reply(std::FILE *replies, const char *text) {
    std::fprintf(replies, "obsbot-ai: %s\n", text);
    std::fflush(replies);
}

static int serve() {
    // ptzd mort (même tué par SIGKILL) pendant que le SDK bloque le fil principal : on sort quand même,
    // sans destructeurs (le système libère l'accès USB), pour ne jamais laisser deux utilitaires.
    const pid_t parent = getppid();
    if (parent == 1) {
        _exit(0);
    }
    std::thread([parent] {
        while (getppid() == parent) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
        _exit(0);
    }).detach();
    // La vraie sortie standard devient le canal des réponses ; le descripteur 1 pointe désormais sur
    // l'erreur standard, où va tout le bruit du SDK. Copie en close-on-exec : un processus lancé par le SDK
    // ne doit pas garder ce tuyau ouvert.
    const int replyFd = fcntl(1, F_DUPFD_CLOEXEC, 3);
    std::FILE *replies = replyFd >= 0 ? fdopen(replyFd, "w") : nullptr;
    if (replies == nullptr || dup2(2, 1) < 0) {
        std::fprintf(stderr, "obsbot-ai : sortie des réponses indisponible\n");
        return 2;
    }
    auto tiny2 = findTiny2();
    if (!tiny2) {
        notFound(replies);
    }
    reply(replies, "ready");
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line != "on" && line != "off") {
            reply(replies, "err 3");
        } else if (setTracking(tiny2, line == "on") == RM_RET_OK) {
            reply(replies, "ok");
        } else {
            reply(replies, "err 2");
        }
    }
    Devices::get().close();
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "serve") == 0) {
        return serve();
    }
    if (argc != 2 || (std::strcmp(argv[1], "on") != 0 && std::strcmp(argv[1], "off") != 0)) {
        std::fprintf(stderr, "usage : obsbot-ai on|off|serve\n");
        return 3;
    }
    const bool on = std::strcmp(argv[1], "on") == 0;
    auto tiny2 = findTiny2();
    if (!tiny2) {
        notFound(nullptr);
    }
    int32_t result = setTracking(tiny2, on);
    Devices::get().close();
    if (result != RM_RET_OK) {
        std::fprintf(stderr, "obsbot-ai : cameraSetAiModeU a renvoyé %d\n", result);
        return 2;
    }
    std::printf("obsbot-ai : suivi IA %s\n", on ? "allumé" : "coupé");
    return 0;
}
