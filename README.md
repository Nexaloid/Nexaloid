# Nexaloid CPP Release Branch

This branch tracks the latest released Nexaloid CPP entry files.

Version: 0.1.13

## Use

Download the matching `nexaloid-cpp-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
c++ -std=c++17 -Iinclude examples/regression.cpp -Llib -lnexaloid -o regression
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.
