# Nexaloid CPP Release Branch

This branch tracks the latest released Nexaloid CPP entry files.

Version: 0.1.28

## Use

Download the matching `nexaloid-cpp-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
c++ -std=c++17 -Iinclude examples/regression.cpp -Llib -lnexaloid -o regression
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.

## Token Contract

Search preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. RecallSearch also adds explicit lattice candidates.

`NxToken.source` identifies the token origin. For rule tokens, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

The optional BMES HMM lattice artifact is bundled at `data/hmm/bmes_hmm_wordhub_lattice.nxhmm`.
The optional HMM CandidateProvider plugin source is bundled at `plugins/hmm_lattice_plugin.zig`.
The entity CandidateProvider plugin source is bundled at `plugins/entity_bmes_plugin.zig`.
Matching release assets include prebuilt `lib/nexaloid_plugin_hmm_lattice.*` and
`lib/nexaloid_plugin_entity_bmes.*` libraries when available.
Use the artifact path directly as plugin config, or pass JSON like `{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}` to calibrate HMM candidate weight.
The release-safe entity model is bundled at `data/entity/entity_bmes_perceptron.nxbmes`.
