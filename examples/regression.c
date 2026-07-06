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

    nx_engine_free(engine);
    puts("c regression passed");
    return 0;
}
