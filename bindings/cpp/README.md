# Nexaloid C++ SDK

Header-only C++ wrapper over the stable Nexaloid C ABI.

Use the `include/`, `lib/`, and `data/` directories from the matching `nexaloid-cpp` release asset.

## Usage

```cpp
#include <iostream>
#include "nexaloid.hpp"

int main() {
    NxConfig config{};
    config.dict_path = "data/dict/nexaloid.nxdict";
    nexaloid::Tokenizer tokenizer(config);

    for (const auto& token : tokenizer.tokenize("昨日中概股集体跌超百分之五", nexaloid::Mode::Search)) {
        std::cout << token.text << " source=" << nexaloid::source_name(token.source)
                  << " flags=" << token.flags << '\n';
    }
}
```

## Token Contract

`Mode::Search` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `Mode::RecallSearch` also adds explicit lattice candidates.

`Token::source` uses the public `Source` enum and `source_name()` returns its stable name. When `source == Source::Rule`, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Development

```powershell
zig c++ -std=c++17 -Icore/include -Ibindings/cpp/include bindings/cpp/tests/regression.cpp core/zig-out/lib/nexaloid.lib -o .zig-cache/nexaloid_cpp_regression.exe
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
.\.zig-cache\nexaloid_cpp_regression.exe
```
