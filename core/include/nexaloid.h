#ifndef NEXALOID_H
#define NEXALOID_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque engine handle. Callers must create, use, and free it through the C ABI. */
typedef struct NxEngine NxEngine;

/* All ABI functions return NxStatus; use nx_status_message for readable errors. */
typedef enum {
    NX_OK = 0,
    NX_ERR_INVALID_UTF8 = 1,
    NX_ERR_OUT_OF_MEMORY = 2,
    NX_ERR_INVALID_CONFIG = 3,
    NX_ERR_IO = 4,
    NX_ERR_PLUGIN = 5,
    NX_ERR_INTERNAL = 255
} NxStatus;

/* Tokenization modes. Search expands the best path; recall search exposes all candidate edges. */
typedef enum {
    NX_MODE_ACCURATE = 0,
    NX_MODE_FULL = 1,
    NX_MODE_SEARCH = 2,
    NX_MODE_RECALL_SEARCH = 3
} NxMode;

/* Source of a token or candidate edge, used for debugging and result explanation. */
typedef enum {
    NX_SOURCE_BASE_DICT = 1,
    NX_SOURCE_USER_DICT = 2,
    NX_SOURCE_DOMAIN_DICT = 3,
    NX_SOURCE_RULE = 4,
    NX_SOURCE_UNKNOWN = 5,
    NX_SOURCE_PLUGIN = 6
} NxSource;

/* Built-in rule ids for nx_set_rule_config. */
typedef enum {
    NX_RULE_URL = 0,
    NX_RULE_EMAIL = 1,
    NX_RULE_TIMESTAMP = 2,
    NX_RULE_WINDOWS_PATH = 3,
    NX_RULE_IPV6 = 4,
    NX_RULE_NUMBER_UNIT = 5,
    NX_RULE_MARKET_DAY = 6,
    NX_RULE_ASCII_TERM = 7,
    NX_RULE_COUNT = 8
} NxRuleId;

#define NX_RULE_ALL_MASK ((uint32_t)((1u << NX_RULE_COUNT) - 1u))

/* Engine configuration. String pointers are owned by the caller and read during init only. */
typedef struct {
    /* Main dictionary path. The current loader accepts UTF-8 TSV files. */
    const char *dict_path;
    /* User dictionary path, loaded as an overlay into the native trie. */
    const char *user_dict_path;
    /* Reserved switch; HMM is not implemented yet. */
    uint32_t enable_hmm;
    /* Reserved switch for future core normalization. */
    uint32_t enable_normalization;
    /* Reserved switch for the future plugin system. */
    uint32_t enable_plugins;
    /* Preserve pure whitespace tokens in accurate/full modes. Default 0 keeps search/RAG-friendly filtering. */
    uint32_t preserve_whitespace;
    /* ABI extension slots; consume these before changing struct size. */
    uint32_t reserved[7];
} NxConfig;

/* Output token. Both byte and char offsets are kept to preserve exact source slicing. */
typedef struct {
    /* UTF-8 byte offsets, half-open range [start_byte, end_byte). */
    uint32_t start_byte;
    uint32_t end_byte;
    /* Unicode codepoint offsets, half-open range [start_char, end_char). */
    uint32_t start_char;
    uint32_t end_char;
    /* Dictionary word id; rule and unknown tokens may use 0. */
    uint32_t word_id;
    /* POS id. v0.1 keeps the field but does not resolve POS tags yet. */
    uint16_t pos_id;
    /* NxSource value describing where the token came from. */
    uint16_t source;
    /* Reserved flags for search expansion, normalization state, and future metadata. */
    uint16_t flags;
    /* Decoder score. Larger is better. */
    float score;
} NxToken;

/* Single-text callback. The token pointer is valid only during the callback. */
typedef void (*NxTokenCallback)(
    const NxToken *token,
    const char *text,
    size_t text_len,
    void *user_data
);

/* Batch callback. Core may compute in parallel, but emits callbacks in input order. */
typedef void (*NxBatchTokenCallback)(
    uint32_t text_index,
    const NxToken *token,
    const char *text,
    size_t text_len,
    void *user_data
);

/* Create an engine. On success, callers must release it with nx_engine_free. */
NxStatus nx_engine_new(const NxConfig *config, NxEngine **out_engine);

/* Free an engine. NULL is allowed. */
void nx_engine_free(NxEngine *engine);

/* Configure built-in rule matcher behavior. enabled_mask uses 1u << NxRuleId.
   scores may be NULL; otherwise score_count entries override default rule scores
   in NxRuleId order. Existing defaults are 300 for structured rules and 3 for
   NX_RULE_ASCII_TERM. */
NxStatus nx_set_rule_config(
    NxEngine *engine,
    uint32_t enabled_mask,
    const float *scores,
    size_t score_count
);

/* Load custom structured rules from JSON. Parsing and validation are owned by
   the core so every language binding has identical behavior. Supported v1
   custom kinds are prefixed_number and charset_span. */
NxStatus nx_load_rules_json(
    NxEngine *engine,
    const char *json,
    size_t json_len
);

/* Remove custom rules loaded by nx_load_rules_json. Built-in rules remain. */
NxStatus nx_clear_rules(NxEngine *engine);

/* Load a CandidateProvider plugin dynamic library into an engine.
   config_json may be NULL. Loaded plugins are released by nx_engine_free. */
NxStatus nx_load_plugin(NxEngine *engine, const char *plugin_path, const char *config_json);

/* Tokenize one UTF-8 byte slice. text does not need to be NUL-terminated.
   Concurrent tokenization on one engine is allowed; do not call nx_add_word or
   nx_reload_user_dict concurrently with tokenization on the same engine. */
NxStatus nx_tokenize(
    NxEngine *engine,
    const char *text,
    size_t text_len,
    NxMode mode,
    NxTokenCallback callback,
    void *user_data
);

/* Tokenize a batch. thread_count 0 lets core choose based on CPU count. */
NxStatus nx_tokenize_batch(
    NxEngine *engine,
    const char *const *texts,
    const size_t *text_lens,
    size_t text_count,
    NxMode mode,
    uint32_t thread_count,
    NxBatchTokenCallback callback,
    void *user_data
);

/* Reload a user dictionary overlay. Not safe to run concurrently with tokenization on the same engine.
   Current implementation appends/overwrites words. */
NxStatus nx_reload_user_dict(NxEngine *engine, const char *user_dict_path);

/* Add a word at runtime. Not safe to run concurrently with tokenization on the same engine.
   word_id 0 lets core allocate an id. */
NxStatus nx_add_word(
    NxEngine *engine,
    const char *word,
    size_t word_len,
    uint32_t word_id,
    float score,
    uint16_t pos_id
);

/* Return a static error string. Callers must not free it. */
const char *nx_status_message(NxStatus status);

#ifdef __cplusplus
}
#endif

#endif
