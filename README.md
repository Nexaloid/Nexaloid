# Nexaloid C Release Branch

This branch tracks the latest released Nexaloid C entry files.

Version: 0.1.11

## Use

Download the matching `nexaloid-c-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
cc -std=c11 -Iinclude examples/regression.c -Llib -lnexaloid -o regression
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.
