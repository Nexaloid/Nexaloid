# Nexaloid ZIG Release Branch

This branch tracks the latest released Nexaloid ZIG entry files.

Version: 0.1.20

## Use

Download the matching `nexaloid-zig-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
zig build-exe examples/regression.zig -Iinclude -Llib -lnexaloid -lc
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.
The optional BMES HMM lattice artifact is bundled at `data/hmm/bmes_hmm_wordhub_lattice.json`.
The optional HMM CandidateProvider plugin source is bundled at `plugins/hmm_lattice_plugin.zig`.
Matching release assets include a prebuilt `lib/nexaloid_plugin_hmm_lattice.*` when available.
Use the artifact path directly as plugin config, or pass JSON like `{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.json","hmm_score":-14.0}` to calibrate HMM candidate weight.
