# Nexaloid C SDK

Stable C ABI for the Nexaloid Chinese tokenizer.

Use the `include/`, `lib/`, and `data/` directories from the matching `nexaloid-c` release asset.

## Usage

```c
#include <stdio.h>
#include <string.h>
#include "nexaloid.h"

static void on_token(const NxToken *token, const char *text, size_t text_len, void *user_data) {
    (void)text_len;
    (void)user_data;
    printf("%.*s source=%u flags=%u\n",
           (int)(token->end_byte - token->start_byte),
           text + token->start_byte,
           (unsigned)token->source,
           (unsigned)token->flags);
    if (token->source == NX_SOURCE_RULE && token->flags != 0) {
        printf("custom rule index=%u\n", (unsigned)token->flags);
    }
}

int main(void) {
    NxConfig config = {0};
    config.dict_path = "data/dict/nexaloid.nxdict";
    NxEngine *engine = NULL;
    if (nx_engine_new(&config, &engine) != NX_OK) return 1;
    const char *text = "昨日中概股集体跌超百分之五";
    NxStatus status = nx_tokenize(engine, text, strlen(text), NX_MODE_SEARCH, on_token, NULL);
    nx_engine_free(engine);
    return status == NX_OK ? 0 : 1;
}
```

## Token Contract

`NX_MODE_SEARCH` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `NX_MODE_RECALL_SEARCH` also adds explicit lattice candidates.

`NxToken.source` is an `NxSource` value. For `NX_SOURCE_RULE`, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Development

```powershell
zig cc -std=c11 -Icore/include bindings/c/tests/regression.c core/zig-out/lib/nexaloid.lib -o .zig-cache/nexaloid_c_regression.exe
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
.\.zig-cache\nexaloid_c_regression.exe
```
