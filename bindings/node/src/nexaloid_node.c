#include <node_api.h>
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
} TokenizeContext;

static napi_ref tokenizer_ctor;

static napi_value throw_status(napi_env env, NxStatus status) {
  napi_throw_error(env, NULL, nx_status_message(status));
  return NULL;
}

static bool get_string_arg(napi_env env, napi_value value, char **out, size_t *out_len) {
  /* N-API strings are copied to NUL-terminated UTF-8 buffers for the C ABI. */
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) return false;
  char *buf = (char *)malloc(len + 1);
  if (buf == NULL) return false;
  if (napi_get_value_string_utf8(env, value, buf, len + 1, out_len) != napi_ok) {
    free(buf);
    return false;
  }
  *out = buf;
  return true;
}

static NodeTokenizer *unwrap_tokenizer(napi_env env, napi_callback_info info) {
  napi_value self;
  if (napi_get_cb_info(env, info, NULL, NULL, &self, NULL) != napi_ok) return NULL;
  NodeTokenizer *tokenizer = NULL;
  if (napi_unwrap(env, self, (void **)&tokenizer) != napi_ok) return NULL;
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

static void on_token(const NxToken *token, const char *text, size_t text_len, void *user_data) {
  (void)text_len;
  TokenizeContext *ctx = (TokenizeContext *)user_data;
  napi_env env = ctx->env;

  napi_value item;
  napi_create_object(env, &item);

  /* Copy token text into a JS string while the callback text pointer is valid. */
  napi_value value;
  napi_create_string_utf8(env, text + token->start_byte, token->end_byte - token->start_byte, &value);
  napi_set_named_property(env, item, "text", value);
  napi_create_uint32(env, token->start_byte, &value);
  napi_set_named_property(env, item, "startByte", value);
  napi_create_uint32(env, token->end_byte, &value);
  napi_set_named_property(env, item, "endByte", value);
  napi_create_uint32(env, token->start_char, &value);
  napi_set_named_property(env, item, "startChar", value);
  napi_create_uint32(env, token->end_char, &value);
  napi_set_named_property(env, item, "endChar", value);
  napi_create_uint32(env, token->word_id, &value);
  napi_set_named_property(env, item, "wordId", value);
  napi_create_uint32(env, token->pos_id, &value);
  napi_set_named_property(env, item, "posId", value);
  napi_create_uint32(env, token->source, &value);
  napi_set_named_property(env, item, "source", value);
  napi_create_double(env, token->score, &value);
  napi_set_named_property(env, item, "score", value);

  napi_set_element(env, ctx->array, ctx->count++, item);
}

static void on_text(const NxToken *token, const char *text, size_t text_len, void *user_data) {
  (void)text_len;
  TokenizeContext *ctx = (TokenizeContext *)user_data;
  napi_value value;
  napi_create_string_utf8(ctx->env, text + token->start_byte, token->end_byte - token->start_byte, &value);
  napi_set_element(ctx->env, ctx->array, ctx->count++, value);
}

static napi_value tokenizer_new(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = (NodeTokenizer *)calloc(1, sizeof(NodeTokenizer));
  if (tokenizer == NULL) {
    napi_throw_error(env, NULL, "out of memory");
    return NULL;
  }

  NxConfig config;
  memset(&config, 0, sizeof(config));

  char *dict_path = NULL;
  size_t dict_path_len = 0;
  if (argc > 0 && get_string_arg(env, args[0], &dict_path, &dict_path_len)) {
    (void)dict_path_len;
    config.dict_path = dict_path;
  }
  bool preserve_whitespace = false;
  if (argc > 1) {
    napi_get_value_bool(env, args[1], &preserve_whitespace);
    config.preserve_whitespace = preserve_whitespace ? 1 : 0;
  }

  NxStatus status = nx_engine_new(&config, &tokenizer->engine);
  free(dict_path);
  if (status != NX_OK) {
    free(tokenizer);
    return throw_status(env, status);
  }

  napi_wrap(env, self, tokenizer, finalize_tokenizer, NULL, NULL);
  return self;
}

static napi_value tokenizer_close(napi_env env, napi_callback_info info) {
  NodeTokenizer *tokenizer = unwrap_tokenizer(env, info);
  if (tokenizer != NULL && tokenizer->engine != NULL) {
    nx_engine_free(tokenizer->engine);
    tokenizer->engine = NULL;
  }
  return NULL;
}

static napi_value tokenizer_tokenize(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *text = NULL;
  size_t text_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &text, &text_len)) {
    napi_throw_type_error(env, NULL, "text must be a string");
    return NULL;
  }

  uint32_t mode = NX_MODE_ACCURATE;
  if (argc > 1) napi_get_value_uint32(env, args[1], &mode);

  TokenizeContext ctx;
  ctx.env = env;
  ctx.count = 0;
  napi_create_array(env, &ctx.array);

  /* Tokenization stays in native core; JS only receives copied token objects. */
  NxStatus status = nx_tokenize(tokenizer->engine, text, text_len, (NxMode)mode, on_token, &ctx);
  free(text);
  if (status != NX_OK) return throw_status(env, status);
  return ctx.array;
}

static napi_value tokenizer_lcut(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *text = NULL;
  size_t text_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &text, &text_len)) {
    napi_throw_type_error(env, NULL, "text must be a string");
    return NULL;
  }

  uint32_t mode = NX_MODE_ACCURATE;
  if (argc > 1) napi_get_value_uint32(env, args[1], &mode);

  TokenizeContext ctx;
  ctx.env = env;
  ctx.count = 0;
  napi_create_array(env, &ctx.array);

  NxStatus status = nx_tokenize(tokenizer->engine, text, text_len, (NxMode)mode, on_text, &ctx);
  free(text);
  if (status != NX_OK) return throw_status(env, status);
  return ctx.array;
}

static napi_value tokenizer_add_word(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *word = NULL;
  size_t word_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &word, &word_len)) {
    napi_throw_type_error(env, NULL, "word must be a string");
    return NULL;
  }

  double score = 10.0;
  if (argc > 1) napi_get_value_double(env, args[1], &score);
  NxStatus status = nx_add_word(tokenizer->engine, word, word_len, 0, (float)score, 0);
  free(word);
  if (status != NX_OK) return throw_status(env, status);
  return NULL;
}

static napi_value tokenizer_load_userdict(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *path = NULL;
  size_t path_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &path, &path_len)) {
    napi_throw_type_error(env, NULL, "path must be a string");
    return NULL;
  }

  (void)path_len;
  NxStatus status = nx_reload_user_dict(tokenizer->engine, path);
  free(path);
  if (status != NX_OK) return throw_status(env, status);
  return NULL;
}

static napi_value tokenizer_load_plugin(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *path = NULL;
  size_t path_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &path, &path_len)) {
    napi_throw_type_error(env, NULL, "path must be a string");
    return NULL;
  }

  char *config = NULL;
  size_t config_len = 0;
  if (argc > 1) {
    if (!get_string_arg(env, args[1], &config, &config_len)) {
      free(path);
      napi_throw_type_error(env, NULL, "config must be a string");
      return NULL;
    }
  }

  (void)path_len;
  (void)config_len;
  NxStatus status = nx_load_plugin(tokenizer->engine, path, config);
  free(path);
  free(config);
  if (status != NX_OK) return throw_status(env, status);
  return NULL;
}

static napi_value tokenizer_load_rules_json(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_value self;
  napi_get_cb_info(env, info, &argc, args, &self, NULL);

  NodeTokenizer *tokenizer = NULL;
  napi_unwrap(env, self, (void **)&tokenizer);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }

  char *json = NULL;
  size_t json_len = 0;
  if (argc == 0 || !get_string_arg(env, args[0], &json, &json_len)) {
    napi_throw_type_error(env, NULL, "json must be a string");
    return NULL;
  }

  NxStatus status = nx_load_rules_json(tokenizer->engine, json, json_len);
  free(json);
  if (status != NX_OK) return throw_status(env, status);
  return NULL;
}

static napi_value tokenizer_clear_rules(napi_env env, napi_callback_info info) {
  NodeTokenizer *tokenizer = unwrap_tokenizer(env, info);
  if (tokenizer == NULL || tokenizer->engine == NULL) {
    napi_throw_error(env, NULL, "tokenizer is closed");
    return NULL;
  }
  NxStatus status = nx_clear_rules(tokenizer->engine);
  if (status != NX_OK) return throw_status(env, status);
  return NULL;
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
  napi_define_class(env, "Tokenizer", NAPI_AUTO_LENGTH, tokenizer_new, NULL, 8, methods, &ctor);
  napi_create_reference(env, ctor, 1, &tokenizer_ctor);
  napi_set_named_property(env, exports, "Tokenizer", ctor);
  return exports;
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
