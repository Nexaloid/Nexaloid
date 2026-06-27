#include "nexaloid.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    size_t tokens;
} CountCtx;

static void on_token(const NxToken *token, const char *text, size_t text_len, void *user_data) {
    (void)token;
    (void)text;
    (void)text_len;
    ((CountCtx *)user_data)->tokens++;
}

static double now_s(void) {
    return (double)clock() / (double)CLOCKS_PER_SEC;
}

static size_t utf8_safe_len(const unsigned char *buf, size_t len) {
    if (len == 0) return 0;
    size_t start = len - 1;
    while (start > 0 && (buf[start] & 0xC0) == 0x80) start--;
    unsigned char lead = buf[start];
    size_t need = 1;
    if ((lead & 0x80) == 0) need = 1;
    else if ((lead & 0xE0) == 0xC0) need = 2;
    else if ((lead & 0xF0) == 0xE0) need = 3;
    else if ((lead & 0xF8) == 0xF0) need = 4;
    else return start;
    return start + need <= len ? len : start;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: stress_core <dict.nxdict> <file> [limit_mb]\n");
        return 2;
    }

    const size_t limit = argc >= 4 ? (size_t)atoll(argv[3]) * 1024 * 1024 : 128u * 1024 * 1024;
    NxConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.dict_path = argv[1];

    NxEngine *engine = NULL;
    double t0 = now_s();
    NxStatus status = nx_engine_new(&cfg, &engine);
    double init_s = now_s() - t0;
    if (status != NX_OK) {
        fprintf(stderr, "engine_new: %s\n", nx_status_message(status));
        return 1;
    }

    FILE *f = fopen(argv[2], "rb");
    if (!f) {
        perror(argv[2]);
        nx_engine_free(engine);
        return 1;
    }

    const size_t chunk_size = 1024 * 1024;
    unsigned char *buf = (unsigned char *)malloc(chunk_size);
    if (!buf) return 1;

    CountCtx ctx = {0};
    size_t bytes = 0;
    double start = now_s();
    while (bytes < limit) {
        size_t want = chunk_size;
        if (limit - bytes < want) want = limit - bytes;
        size_t n = fread(buf, 1, want, f);
        if (n == 0) break;
        size_t safe = utf8_safe_len(buf, n);
        status = nx_tokenize(engine, (const char *)buf, safe, NX_MODE_ACCURATE, on_token, &ctx);
        if (status != NX_OK) {
            fprintf(stderr, "tokenize: %s\n", nx_status_message(status));
            break;
        }
        bytes += safe;
        if (safe < n) {
            if (safe == 0) {
                bytes += 1;
            } else {
                fseek(f, (long)safe - (long)n, SEEK_CUR);
            }
        }
    }
    double elapsed = now_s() - start;

    printf("init_s\t%.4f\n", init_s);
    printf("mb\t%.2f\n", (double)bytes / 1024.0 / 1024.0);
    printf("tokenize_s\t%.4f\n", elapsed);
    printf("mbps\t%.2f\n", ((double)bytes / 1024.0 / 1024.0) / elapsed);
    printf("tokens\t%zu\n", ctx.tokens);

    free(buf);
    fclose(f);
    nx_engine_free(engine);
    return status == NX_OK ? 0 : 1;
}
