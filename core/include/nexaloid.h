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

/* Tokenization modes. Accurate/search are implemented; full is kept for API compatibility. */
typedef enum {
    NX_MODE_ACCURATE = 0,
    NX_MODE_FULL = 1,
    NX_MODE_SEARCH = 2
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
    /* ABI extension slots; consume these before changing struct size. */
    uint32_t reserved[8];
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

/* Tokenize one UTF-8 byte slice. text does not need to be NUL-terminated. */
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

/* Reload a user dictionary overlay. Current implementation appends/overwrites words. */
NxStatus nx_reload_user_dict(NxEngine *engine, const char *user_dict_path);

/* Add a word at runtime. word_id 0 lets core allocate an id. */
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
