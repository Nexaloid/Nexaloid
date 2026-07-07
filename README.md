# Nexaloid ZIG Release Branch

This branch tracks the latest released Nexaloid ZIG entry files.

Version: 0.1.14

## Use

Download the matching `nexaloid-zig-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
zig build-exe examples/regression.zig -Iinclude -Llib -lnexaloid -lc
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.
