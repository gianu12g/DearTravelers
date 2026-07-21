# Merge Object Model Replacement

Merge objects use an invisible gameplay root for placement, pickup, carrying,
merging, and income tracking. Their artwork is cloned separately, so replacing
a model cannot break those systems.

## Template location

In Roblox Studio, open:

`ServerStorage > MergeObjectModels`

The folder contains one template per merge tier:

`Tier1`, `Tier2`, ... `Tier10`

Each template may be a `Model` or a single `BasePart`. To replace a tier, swap
that template while keeping its `TierN` name.

## Model contract

- Set a `PrimaryPart` on each `Model`; its orientation defines forward and up.
- Author the model at its intended in-game scale.
- The system centers its bounding box horizontally and rests its bottom on the
  pad automatically, so the model pivot does not need a special position.
- Use the numeric `RotationX`, `RotationY`, and `RotationZ` attributes on the
  `TierN` template to correct its orientation in degrees. Rotation is applied
  in local X/Y/Z order, and the model is bottom-aligned again afterward.
- Use `CarryRotationX`, `CarryRotationY`, and `CarryRotationZ` for a separate
  orientation while the player is carrying that tier. Dropping, cancelling,
  or merging restores the normal `RotationX/Y/Z` orientation automatically.
- Set `MushSoundId` to that tier's numeric Roblox audio asset ID (stored as a
  string) and `MushSoundVolume` to its playback volume. An empty ID keeps the
  Mush animation and speed reward but makes that tier's interaction silent.
- Set the string `MushDirection` to `Top`, `Bottom`, `Left`, `Right`, `Front`,
  or `Back`. It controls which local side presses into the model; `Front` is
  local -Z. Missing or invalid values safely use `Top`.
- Visual parts are made massless and non-collidable, then welded to the hidden
  gameplay root. The root remains the only pickup and merge hitbox.
- Scripts inside templates are removed when cloned. Attachments, particles,
  textures, meshes, and other visual descendants are preserved.
- If a template is missing or invalid, the old colored cube appears instead.

`MergeConfig.Tiers[tier].Size` remains the gameplay footprint used for spacing,
pickup distance, carrying distance, and the fallback cube. Adjust it when a new
model needs more or less room on the pad.
