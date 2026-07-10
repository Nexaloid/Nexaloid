# Entity BMES Model

`tools/entity_bmes_plugin.zig` loads `.nxbmes` artifacts produced by the
separate `NexaloidBMES` training repository.

The current trained artifact is intentionally not distributed from this
public repository because its upstream training and gazetteer licenses are
not cleared for public commercial release. Once a NexaloidBMES release is
explicitly cleared, the Nexaloid release workflow can attach it as a separate,
pinned `nexaloid-entity-bmes-<version>.zip` companion asset. For local checks,
copy the artifact here or set `NEXALOID_ENTITY_BMES_ARTIFACT` to its path.

Manual releases use the `entity_bmes_version` and `entity_bmes_sha256` inputs.
Tag releases use the matching `ENTITY_BMES_VERSION` and
`ENTITY_BMES_SHA256` repository variables. Both values must be present.
