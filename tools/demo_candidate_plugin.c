#include "nexaloid_plugin.h"

#ifdef _WIN32
#define NX_EXPORT __declspec(dllexport)
#else
#define NX_EXPORT __attribute__((visibility("default")))
#endif

struct NxPlugin {
    int unused;
};

static struct NxPlugin plugin_instance = {0};

NX_EXPORT int nx_plugin_init(const char *config_json, NxPlugin **out_plugin) {
    (void)config_json;
    if (out_plugin == 0) return 1;
    *out_plugin = &plugin_instance;
    return 0;
}

NX_EXPORT void nx_plugin_free(NxPlugin *plugin) {
    (void)plugin;
}

NX_EXPORT int nx_plugin_get_info(NxPlugin *plugin, NxPluginInfo *out_info) {
    (void)plugin;
    if (out_info == 0) return 1;
    out_info->abi_version = NX_PLUGIN_ABI_VERSION;
    out_info->name = "demo_candidate_plugin";
    out_info->version = "0.1.0";
    out_info->kind = NX_PLUGIN_CANDIDATE_PROVIDER;
    return 0;
}

NX_EXPORT int nx_plugin_provide_candidates(
    NxPlugin *plugin,
    const NxPluginInput *input,
    NxPluginCandidateCallback callback,
    void *user_data
) {
    (void)plugin;
    if (input == 0 || callback == 0) return 1;
    if (input->char_len < 4) return 0;
    NxPluginCandidate candidate = {
        .start_char = 0,
        .end_char = 4,
        .score = 50.0f,
        .source = 0,
        .flags = 0,
    };
    callback(&candidate, user_data);
    return 0;
}
