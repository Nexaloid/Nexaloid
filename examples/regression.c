#include "nexaloid.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char **expected;
    size_t expected_len;
    size_t count;
    int failed;
} Ctx;

typedef struct {
    int saw_rule;
    int saw_full_ascii;
} RuleCtx;

typedef struct {
    const char *target;
    int saw;
} ContainsCtx;

static void on_token(const NxToken *token, const char *text, size_t text_len, void *user_data) {
    (void)text_len;
    Ctx *ctx = (Ctx *)user_data;
    if (ctx->count >= ctx->expected_len) {
        ctx->failed = 1;
        return;
    }
    const char *expected = ctx->expected[ctx->count++];
    const size_t len = token->end_byte - token->start_byte;
    if (strlen(expected) != len || memcmp(text + token->start_byte, expected, len) != 0) {
        ctx->failed = 1;
    }
}

static void on_rule_check(const NxToken *token, const char *text, size_t text_len, void *user_data) {
    (void)text_len;
    RuleCtx *ctx = (RuleCtx *)user_data;
    if (token->source == NX_SOURCE_RULE) ctx->saw_rule = 1;
    const size_t len = token->end_byte - token->start_byte;
    if (len == strlen("foo_bar-123") && memcmp(text + token->start_byte, "foo_bar-123", len) == 0) {
        ctx->saw_full_ascii = 1;
    }
}

static void on_contains(const NxToken *token, const char *text, size_t text_len, void *user_data) {
    (void)text_len;
    ContainsCtx *ctx = (ContainsCtx *)user_data;
    const size_t len = token->end_byte - token->start_byte;
    if (len == strlen(ctx->target) && memcmp(text + token->start_byte, ctx->target, len) == 0) {
        ctx->saw = 1;
    }
}

static void expect(NxEngine *engine, const char *text, const char **expected, size_t expected_len) {
    Ctx ctx = {.expected = expected, .expected_len = expected_len};
    NxStatus status = nx_tokenize(engine, text, strlen(text), NX_MODE_ACCURATE, on_token, &ctx);
    if (status != NX_OK || ctx.failed || ctx.count != expected_len) {
        fprintf(stderr, "unexpected tokens for %s\n", text);
        exit(1);
    }
}

int main(void) {
    NxConfig cfg = {0};
    cfg.dict_path = "data/dict/nexaloid.tsv";
    NxEngine *engine = NULL;
    if (nx_engine_new(&cfg, &engine) != NX_OK) return 1;

    const char *classic[] = {"南京市", "长江大桥"};
    expect(engine, "南京市长江大桥", classic, 2);
    const char *daily[] = {"我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验"};
    expect(engine, "我们在日本东京做RAG中文检索实验", daily, 9);
    const char *entity[] = {"我", "爱", "北京", "天安门"};
    expect(engine, "我爱北京天安门", entity, 4);
    const char *ambiguous[] = {"长春", "市长", "春节前", "发表", "讲话"};
    expect(engine, "长春市长春节前发表讲话", ambiguous, 5);
    const char *space_filtered[] = {"文档", "秒"};
    expect(engine, "文档 秒", space_filtered, 2);

    if (nx_set_rule_config(engine, NX_RULE_ALL_MASK & ~(1u << NX_RULE_ASCII_TERM), NULL, 0) != NX_OK) return 1;
    RuleCtx rule_ctx = {0};
    if (nx_tokenize(engine, "foo_bar-123", strlen("foo_bar-123"), NX_MODE_ACCURATE, on_rule_check, &rule_ctx) != NX_OK) return 1;
    if (rule_ctx.saw_rule || rule_ctx.saw_full_ascii) return 1;

    const char *rules_json = "{\"version\":1,\"rules\":[{\"name\":\"stock\",\"kind\":\"prefixed_number\",\"prefixes\":[\"SH\"],\"digits\":{\"min\":6,\"max\":6},\"score\":80}]}";
    if (nx_load_rules_json(engine, rules_json, strlen(rules_json)) != NX_OK) return 1;
    rule_ctx = (RuleCtx){0};
    if (nx_tokenize(engine, "买SH600519", strlen("买SH600519"), NX_MODE_ACCURATE, on_rule_check, &rule_ctx) != NX_OK) return 1;
    if (!rule_ctx.saw_rule) return 1;
    if (nx_clear_rules(engine) != NX_OK) return 1;

    ContainsCtx search_ctx = {.target = "研究生"};
    if (nx_tokenize(engine, "研究生命起源", strlen("研究生命起源"), NX_MODE_SEARCH, on_contains, &search_ctx) != NX_OK) return 1;
    if (search_ctx.saw) return 1;
    ContainsCtx recall_ctx = {.target = "研究生"};
    if (nx_tokenize(engine, "研究生命起源", strlen("研究生命起源"), NX_MODE_RECALL_SEARCH, on_contains, &recall_ctx) != NX_OK) return 1;
    if (!recall_ctx.saw) return 1;

    nx_engine_free(engine);

    cfg.preserve_whitespace = 1;
    if (nx_engine_new(&cfg, &engine) != NX_OK) return 1;
    const char *space_preserved[] = {"文档", " ", "秒"};
    expect(engine, "文档 秒", space_preserved, 3);
    nx_engine_free(engine);

    puts("c regression passed");
    return 0;
}
