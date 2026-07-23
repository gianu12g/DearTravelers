# Cosmetics System Plan: Owned Keycap Themes + Squishy Trails

Status: **planned, not yet implemented** (2026-07-23)

## Goal

Players own and equip cosmetics — keycap Themes and squishy launch Trails — with the choice persisted in the data profile and applied via replication/observe. Theme bundles will be sold in the shop **later**; this pass builds the ownership + equip backbone and the cosmetics menu only, keeping store logic fully separate.

Architecture backbone (deliberate): **equip = a `DataService.set` write; `DataController.observe` on the replicated value drives the UI; world visuals follow automatically.**

## Decisions (locked)

- Ownership from day one: new players own only the defaults (`ChocolateBar` theme, `DefaultLaunchTrail` trail). Bundles grant more later via a `CosmeticsService.grant` API — no purchase flow in this pass.
- The cosmetics menu shows **only owned items** (no locked teasers; template `Purchase` button hidden here — shop reuses the card later with it visible).
- Trails use the same ownership model as themes.
- Unequip = revert to the default id (equipped id is never empty).
- A theme applies to the player's whole base and is visible to all players (server stamps the `Theme` attribute; existing `KeyCapsController` attribute observers render it on every client).
- The ~1600-line visual `THEMES` table stays client-side in `KeyCapsController`; a small shared catalog holds ids + display names only. A dev-time drift guard warns on divergence.

## Data (DataService TEMPLATE — new field, no version bump)

```lua
Cosmetics = {
    KeycapThemeId = "ChocolateBar",
    SquishyTrailId = "DefaultLaunchTrail",
    Owned = {
        KeycapThemes = { "ChocolateBar" } :: { string },
        SquishyTrails = { "DefaultLaunchTrail" } :: { string },
    },
},
```

`repairProfileData` invariants: dedupe Owned arrays, drop unknown ids, defaults always owned, equipped id must be owned (else revert to default).

## Changes (implementation order)

1. **Create `src/shared/CosmeticsCatalog.luau`** — id + DisplayName catalogs for both slots, `KeyTag`/`ThemeAttribute`/default-id constants, O(1) `isKeycapTheme`/`isSquishyTrail` validators. Single id authority; future shop bundles reference these ids.
2. **Modify `src/shared/Net.luau`** — `cosmeticEquip` client→server packet (`{ slot, id }`) in the `"Game"` namespace. No result packet: result-via-replication.
3. **Modify `src/server/Services/DataService.luau`** — TEMPLATE field + repair invariants above.
4. **Modify `src/server/Services/BaseService.luau`** — add `BaseService.getBasePart(player): BasePart?`.
5. **Create `src/server/Services/CosmeticsService.luau`** —
   - `Init`: `cosmeticEquip` listener: rate-limit → data loaded → catalog-valid → **owned** → `DataService.set`; themes also apply immediately.
   - `grant(player, slot, id)`: validates, no-ops if owned, else `DataService.tableInsert` into the Owned array (the shop's future entry point; menu updates live via observe).
   - `applyKeycapTheme(player, id)`: stamp `Theme` attribute on all `Key`-tagged MeshParts under the player's base `KeyCaps` folder.
   - `Start`: re-apply persisted theme on `AssignedBase` attribute set (plus initial pass; awaitData first; disconnect on leave).
6. **Modify `src/server/Services/MergeService.luau`** — build `trailTemplates` map from `Assets.VFX.LaunchTrails` children in `Start`; rename `attachDefaultLaunchTrail(launch)` → `attachLaunchTrail(player, launch)` resolving the player's equipped trail with default fallback; update the single call site (launch path, ~line 1667).
7. **Modify `src/client/UI/UISystem/Frames.luau`** — register `"Cosmetics"` in `FrameName` + `STUDIO_NAMES`.
8. **Create `src/client/Controllers/UISystem/CosmeticsController.luau`** — `Start()` only (no Init; `Frames.get` yields). Binds the existing Studio UI:
   - `Top.Keys` / `Top.Trails` tabs pick the active slot; `Top.Close` already has `Ui-Close = true`.
   - Clones `MainScrollingFrame.Holder.ThemeTemplate1` per **owned** entry (one template serves both tabs): `Name = id`, `Title.Text = DisplayName`, `Purchase.Visible = false`. Never touches the template original or `UIListLayout`.
   - `EquipButton` click: not equipped → send equip; equipped non-default → send equip default (= unequip); equipped default → no-op.
   - `DataController.observe` on `{ "Cosmetics", "KeycapThemeId" }` / `{ "Cosmetics", "SquishyTrailId" }` drives `EquipButton.PriceTag.Text` (`Equip` / `Unequip` / `Equipped`); observe on `{ "Cosmetics", "Owned" }` re-renders so granted items appear live.
9. **Modify `src/client/Controllers/KeyCapsController.luau`** — drift guard: every catalog theme id must exist in `THEMES` (warn otherwise).
10. **Studio-side fixes** (place file, not repo — via Studio MCP in Edit mode):
    - `Main.HUD.Left.Cosmetics` attribute `Ui-Frame`: `"PlaytimeRewards"` (placeholder) → `"Cosmetics"`.
    - Remove placeholder `Ui-Frame` from `Frames.Cosmetics.Top.Keys` (and `Top.Trails` if present) — tabs must not open other panels.
    - Rename `ThemeTemplate1.Equipped/Unequip` → `EquipButton` (slash breaks dot-indexing + naming rules).

## Verification

- Static: `selene src/`, `stylua --check src/`, `rojo build default.project.json` (artifact to temp dir), sourcemap + `luau-lsp analyze` if available.
- Runtime (Studio MCP, restart Play after sync):
  - Fresh profile: menu lists exactly the two defaults, equipped card shows `Equipped` on open.
  - `grant` a theme via `execute_luau` → appears live in the open menu → equip → base keys re-theme for all clients; unequip reverts to ChocolateBar.
  - Grant + equip a trail → next launch uses it; unknown id falls back to default.
  - Forged equip of an unowned id is silently dropped.
  - Rejoin (Studio-isolated store): ownership + equips persist; theme re-applies on base assignment.
- Change-impact: grep `attachDefaultLaunchTrail` (single call site), `FrameName` exhaustive uses, Loader pickup of the two new modules.

## Out of scope (later passes)

- Shop bundle products + purchase flow (will call `CosmeticsService.grant`).
- Showing unowned/locked items or prices in the cosmetics menu.
