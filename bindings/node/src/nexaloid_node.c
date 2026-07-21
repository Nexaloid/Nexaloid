#include <node_api.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "nexaloid.h"

typedef struct {
  /* Opaque native engine handle owned by the JS Tokenizer object. */
  NxEngine *engine;
} NodeTokenizer;

typedef struct {
  napi_env env;
  napi_value array;
  uint32_t count;
  bool failed;
} TokenizeContext;

static napi_ref tokenizer_ctor;

static napi_value throw_status(napi_env env, NxStatus status) {
  (void)napi_throw_error(env, NULL, nx_status_message(status));
  return NULL;
}

static napi_value throw_error(napi_env env, const char *message) {
  (void)napi_throw_error(env, NULL, message);
  return NULL;
}

static napi_value throw_type_error(napi_env env, const char *message) {
  (void)napi_throw_type_error(env, NULL, message);
  return NULL;
}

static bool check_napi(napi_env env, napi_status status, const char *message) {
  if (status == napi_ok) return true;
  bool pending = false;
  if (napi_is_exception_pending(env, &pending) != napi_ok || !pending) {
    (void)napi_throw_error(env, NULL, message);
  }
  return false;
}

static napi_value return_undefined(napi_env env) {
  napi_value value;
  if (!check_napi(env, napi_get_undefined(env, &value), "failed to create undefined value")) return NULL;
  return value;
}

static bool get_string_arg(
    napi_env env,
    napi_value value,
    char **out,
    size_t *out_len,
    const char *type_message) {
  /* N-API strings are copied to NUL-terminated UTF-8 buffers for the C ABI. */
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) {
    (void)napi_throw_type_error(env, NULL, type_message);
    return false;
  }
  if (len == SIZE_MAX) {
    (void)napi_throw_error(env, NULL, "string is too large");
    return false;
  }
  char *buf = (char *)malloc(len + 1);
  if (buf == NULL) {
    (void)napi_throw_error(env, NULL, "out of memory");
    return false;
  }
  if (napi_get_value_string_utf8(env, value, buf, len + 1, out_len) != napi_ok) {
    free(buf);
    (void)napi_throw_type_error(env, NULL, type_message);
    return false;
  }
  *out = buf;
  return true;
}

static NodeTokenizer *unwrap_tokenizer(napi_env env, napi_callback_info info) {
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, NULL, NULL, &self, NULL), "failed to read receiver")) return NULL;
  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  return tokenizer;
}

static void finalize_tokenizer(napi_env env, void *data, void *hint) {
  (void)env;
  (void)hint;
  NodeTokenizer *tokenizer = (NodeTokenizer *)data;
  if (tokenizer != NULL) {
    /* Finalizer is a safety net; close() may have already freed the engine. */
    if (tokenizer->engine != NULL) nx_engine_free(tokenizer->engine);
    free(tokenizer);
  }
}

static const char *source_name(uint16_t source) {
  switch (source) {
    case NX_SOURCE_BASE_DICT: return "base_dict";
    case NX_SOURCE_USER_DICT: return "user_dict";
    case NX_SOURCE_DOMAIN_DICT: return "domain_dict";
    case NX_SOURCE_RULE: return "rule";
    case NX_SOURCE_UNKNOWN: return "unknown";
    case NX_SOURCE_PLUGIN: return "plugin";
    default: return "unrecognized";
  }
}

static void on_token(const NxToken *token, const char *text, size_t text_len, void *user_data) {
  (void)text_len;
  TokenizeContext *ctx = (TokenizeContext *)user_data;
  if (ctx->failed) return;
  napi_env env = ctx->env;

  napi_value item;
  if (!check_napi(env, napi_create_object(env, &item), "failed to create token object")) {
    ctx->failed = true;
    return;
  }

  /* Copy token text into a JS string while the callback text pointer is valid. */
  napi_value value;
#define SET_TOKEN_PROPERTY(create_call, name)                                      \
  do {                                                                             \
    if (!check_napi(env, (create_call), "failed to create token property")) {     \
      ctx->failed = true;                                                          \
      return;                                                                      \
    }                                                                              \
    if (!check_napi(env, napi_set_named_property(env, item, (name), value),        \
                    "failed to set token property")) {                            \
      ctx->failed = true;                                                          \
      return;                                                                      \
    }                                                                              \
  } while (0)

  SET_TOKEN_PROPERTY(
      napi_create_string_utf8(env, text + token->start_byte, token->end_byte - token->start_byte, &value), "text");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->start_byte, &value), "startByte");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->end_byte, &value), "endByte");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->start_char, &value), "startChar");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->end_char, &value), "endChar");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->word_id, &value), "wordId");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->pos_id, &value), "posId");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->source, &value), "source");
  SET_TOKEN_PROPERTY(napi_create_string_utf8(env, source_name(token->source), NAPI_AUTO_LENGTH, &value), "sourceName");
  SET_TOKEN_PROPERTY(napi_create_uint32(env, token->flags, &value), "flags");
  SET_TOKEN_PROPERTY(napi_create_double(env, token->score, &value), "score");

#undef SET_TOKEN_PROPERTY
  if (!check_napi(env, napi_set_element(env, ctx->array, ctx->count, item), "failed to append token")) {
    ctx->failed = true;
    return;
  }
  ctx->count++;
}

static void on_text(const NxToken *token, const char *text, size_t text_len, void *user_data) {
  (void)text_len;
  TokenizeContext *ctx = (TokenizeContext *)user_data;
  if (ctx->failed) return;
  napi_value value;
  if (!check_napi(
          ctx->env,
          napi_create_string_utf8(
              ctx->env, text + token->start_byte, token->end_byte - token->start_byte, &value),
          "failed to create token text") ||
      !check_napi(ctx->env, napi_set_element(ctx->env, ctx->array, ctx->count, value), "failed to append token text")) {
    ctx->failed = true;
    return;
  }
  ctx->count++;
}

static napi_value tokenizer_new(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read constructor arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = (NodeTokenizer *)calloc(1, sizeof(NodeTokenizer));
  if (tokenizer == NULL) {
    return throw_error(env, "out of memory");
  }

  NxConfig config;
  memset(&config, 0, sizeof(config));

  char *dict_path = NULL;
  size_t dict_path_len = 0;
  if (argc > 0) {
    if (!get_string_arg(env, args[0], &dict_path, &dict_path_len, "dictPath must be a string")) {
      free(tokenizer);
      return NULL;
    }
    (void)dict_path_len;
    config.dict_path = dict_path;
  }
  bool preserve_whitespace = false;
  if (argc > 1) {
    if (!check_napi(
            env,
            napi_get_value_bool(env, args[1], &preserve_whitespace),
            "preserveWhitespace must be a boolean")) {
      free(dict_path);
      free(tokenizer);
      return NULL;
    }
    config.preserve_whitespace = preserve_whitespace ? 1 : 0;
  }

  NxStatus status = nx_engine_new(&config, &tokenizer->engine);
  free(dict_path);
  if (status != NX_OK) {
    free(tokenizer);
    return throw_status(env, status);
  }

  if (!check_napi(
          env,
          napi_wrap(env, self, tokenizer, finalize_tokenizer, NULL, NULL),
          "failed to attach native Tokenizer")) {
    nx_engine_free(tokenizer->engine);
    free(tokenizer);
    return NULL;
  }
  return self;
}

static napi_value tokenizer_close(napi_env env, napi_callback_info info) {
  NodeTokenizer *tokenizer = unwrap_tokenizer(env, info);
  if (tokenizer != NULL && tokenizer->engine != NULL) {
    nx_engine_free(tokenizer->engine);
    tokenizer->engine = NULL;
  }
  if (tokenizer == NULL) return NULL;
  return return_undefined(env);
}

static napi_value tokenizer_tokenize(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read tokenize arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *text = NULL;
  size_t text_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "text must be a string");
  }
  if (!get_string_arg(env, args[0], &text, &text_len, "text must be a string")) {
    return NULL;
  }

  uint32_t mode = NX_MODE_ACCURATE;
  if (argc > 1 && !check_napi(env, napi_get_value_uint32(env, args[1], &mode), "mode must be an integer")) {
    free(text);
    return NULL;
  }

  TokenizeContext ctx;
  ctx.env = env;
  ctx.count = 0;
  ctx.failed = false;
  if (!check_napi(env, napi_create_array(env, &ctx.array), "failed to create token array")) {
    free(text);
    return NULL;
  }

  /* Tokenization stays in native core; JS only receives copied token objects. */
  NxStatus status = nx_tokenize(tokenizer->engine, text, text_len, (NxMode)mode, on_token, &ctx);
  free(text);
  if (ctx.failed) return NULL;
  if (status != NX_OK) return throw_status(env, status);
  return ctx.array;
}

static napi_value tokenizer_lcut(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read lcut arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *text = NULL;
  size_t text_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "text must be a string");
  }
  if (!get_string_arg(env, args[0], &text, &text_len, "text must be a string")) {
    return NULL;
  }

  uint32_t mode = NX_MODE_ACCURATE;
  if (argc > 1 && !check_napi(env, napi_get_value_uint32(env, args[1], &mode), "mode must be an integer")) {
    free(text);
    return NULL;
  }

  TokenizeContext ctx;
  ctx.env = env;
  ctx.count = 0;
  ctx.failed = false;
  if (!check_napi(env, napi_create_array(env, &ctx.array), "failed to create token array")) {
    free(text);
    return NULL;
  }

  NxStatus status = nx_tokenize(tokenizer->engine, text, text_len, (NxMode)mode, on_text, &ctx);
  free(text);
  if (ctx.failed) return NULL;
  if (status != NX_OK) return throw_status(env, status);
  return ctx.array;
}

static napi_value tokenizer_add_word(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read addWord arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *word = NULL;
  size_t word_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "word must be a string");
  }
  if (!get_string_arg(env, args[0], &word, &word_len, "word must be a string")) {
    return NULL;
  }

  double score = 10.0;
  if (argc > 1 && !check_napi(env, napi_get_value_double(env, args[1], &score), "score must be a number")) {
    free(word);
    return NULL;
  }
  NxStatus status = nx_add_word(tokenizer->engine, word, word_len, 0, (float)score, 0);
  free(word);
  if (status != NX_OK) return throw_status(env, status);
  return return_undefined(env);
}

static napi_value tokenizer_load_userdict(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read loadUserdict arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *path = NULL;
  size_t path_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "path must be a string");
  }
  if (!get_string_arg(env, args[0], &path, &path_len, "path must be a string")) {
    return NULL;
  }

  (void)path_len;
  NxStatus status = nx_reload_user_dict(tokenizer->engine, path);
  free(path);
  if (status != NX_OK) return throw_status(env, status);
  return return_undefined(env);
}

static napi_value tokenizer_load_plugin(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read loadPlugin arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *path = NULL;
  size_t path_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "path must be a string");
  }
  if (!get_string_arg(env, args[0], &path, &path_len, "path must be a string")) {
    return NULL;
  }

  char *config = NULL;
  size_t config_len = 0;
  if (argc > 1) {
    if (!get_string_arg(env, args[1], &config, &config_len, "config must be a string")) {
      free(path);
      return NULL;
    }
  }

  (void)path_len;
  (void)config_len;
  NxStatus status = nx_load_plugin(tokenizer->engine, path, config);
  free(path);
  free(config);
  if (status != NX_OK) return throw_status(env, status);
  return return_undefined(env);
}

static napi_value tokenizer_load_rules_json(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_value self;
  if (!check_napi(env, napi_get_cb_info(env, info, &argc, args, &self, NULL), "failed to read loadRulesJson arguments")) {
    return NULL;
  }

  NodeTokenizer *tokenizer = NULL;
  if (!check_napi(env, napi_unwrap(env, self, (void **)&tokenizer), "invalid Tokenizer receiver")) return NULL;
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }

  char *json = NULL;
  size_t json_len = 0;
  if (argc == 0) {
    return throw_type_error(env, "json must be a string");
  }
  if (!get_string_arg(env, args[0], &json, &json_len, "json must be a string")) {
    return NULL;
  }

  NxStatus status = nx_load_rules_json(tokenizer->engine, json, json_len);
  free(json);
  if (status != NX_OK) return throw_status(env, status);
  return return_undefined(env);
}

static napi_value tokenizer_clear_rules(napi_env env, napi_callback_info info) {
  NodeTokenizer *tokenizer = unwrap_tokenizer(env, info);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    return throw_error(env, "tokenizer is closed");
  }
  NxStatus status = nx_clear_rules(tokenizer->engine);
  if (status != NX_OK) return throw_status(env, status);
  return return_undefined(env);
}

static napi_value init(napi_env env, napi_value exports) {
  napi_property_descriptor methods[] = {
    {"tokenize", NULL, tokenizer_tokenize, NULL, NULL, NULL, napi_default, NULL},
    {"lcut", NULL, tokenizer_lcut, NULL, NULL, NULL, napi_default, NULL},
    {"close", NULL, tokenizer_close, NULL, NULL, NULL, napi_default, NULL},
    {"addWord", NULL, tokenizer_add_word, NULL, NULL, NULL, napi_default, NULL},
    {"loadUserdict", NULL, tokenizer_load_userdict, NULL, NULL, NULL, napi_default, NULL},
    {"loadPlugin", NULL, tokenizer_load_plugin, NULL, NULL, NULL, napi_default, NULL},
    {"loadRulesJson", NULL, tokenizer_load_rules_json, NULL, NULL, NULL, napi_default, NULL},
    {"clearRules", NULL, tokenizer_clear_rules, NULL, NULL, NULL, napi_default, NULL}
  };

  napi_value ctor;
  if (!check_napi(
          env,
          napi_define_class(env, "Tokenizer", NAPI_AUTO_LENGTH, tokenizer_new, NULL, 8, methods, &ctor),
          "failed to define Tokenizer class")) return NULL;
  if (!check_napi(env, napi_create_reference(env, ctor, 1, &tokenizer_ctor), "failed to retain Tokenizer class")) {
    return NULL;
  }
  if (!check_napi(env, napi_set_named_property(env, exports, "Tokenizer", ctor), "failed to export Tokenizer class")) {
    (void)napi_delete_reference(env, tokenizer_ctor);
    tokenizer_ctor = NULL;
    return NULL;
  }
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
