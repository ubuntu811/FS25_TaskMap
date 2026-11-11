# Smart Minimap Auto (FS25) — add-on for FS25_minimapPlus

## The pivot from the first scaffold
Your uploaded `FS25_minimapPlus` mod (by 50keda) already patches the base
game's `MapOverlayGenerator` and exposes exactly the field states you asked
for as ready-made overlays:

| MinimapPlus overlay ID | What it shows |
|---|---|
| `NEEDS_ROLLING` | fields the base game considers needing rolling |
| `NEEDS_PLOWING` | fields needing tillage (covers plow *and* cultivator) |
| `WEEDS` | fields with weeds |
| `CROPS` | all fields color-coded by fruit type |
| `GROWTH` | all fields color-coded by growth stage |

This means the hard, uncertain part of the first scaffold — guessing at
field state from density-map samples — isn't needed at all. The base game
already tracks this; MinimapPlus already surfaces it; your mod's whole job
is: **detect what you entered → set MinimapPlus's overlay ID → done.**

Keep MinimapPlus installed. `SmartMinimapAuto` is a separate, small add-on
that drives it — it doesn't replace or modify it.

## What works now vs. what's still a guess
**Solid (verified from MinimapPlus's own source, not guessed):**
- `MMapPlusMapIDs.NEEDS_ROLLING` / `NEEDS_PLOWING` / `WEEDS` / `CROPS` exist
  and are exactly what you set `mapOverlayGenerator.mMapPlusSelectedOverlayType`
  to, followed by `:generateSelectedOverlay(true)`, to force an overlay.

**Still a guess, same caveat as before — run Discovery first:**
- `VehicleClassifier.lua`'s `WorkAreaType` names (roller/cultivator/weeder
  identification). This is unrelated to the overlay system; it's purely
  "what did the player just get into."

## Step 1 — Discovery pass
1. Drop both `FS25_minimapPlus` and `SmartMinimapAuto` into your mods
   folder, enable both.
2. `DISCOVERY_MODE = true` by default in `SmartMinimapAuto.lua`.
3. Load a save, enter a roller, cultivator, weeder, combine+grain header,
   beet/carrot harvester in turn.
4. Check `log.txt` for two things per entry:
   - the `MinimapPlus presence` block — confirms the overlay side is wired
     up correctly for your patch (should show `true` everywhere)
   - the vehicle dump — real `spec_*` names and `WorkAreaType` values, same
     as before, to fill into `VehicleClassifier.lua`

## Step 2 — fill in VehicleClassifier.lua, flip DISCOVERY_MODE off
Same process as the original scaffold — see the comments in that file.

## The one known gap: fruit-filtered harvest overlay
Right now, entering a combine or root-crop harvester shows MinimapPlus's
existing `CROPS` overlay — **all** fruit types color-coded, not narrowed to
just what your header supports (e.g. only beets+carrots). That's a real
limitation, not an oversight: MinimapPlus keeps its live overlay handle in a
`local MMapPlus` table inside `MMapPlus.lua`, which by Lua scoping rules is
invisible outside that file. An add-on mod genuinely cannot reach in and
swap that handle for a custom fruit-filtered one.

Two ways forward, your call:
1. **Leave it** — `CROPS` view is still a real improvement over manually
   cycling with Alt+9/Ctrl+9, you just eyeball the right colors.
2. **One-line edit to MinimapPlus itself**, since you said you're open to
   expanding it: in `MMapPlus.lua`, change
   ```lua
   local MMapPlus = {}
   ```
   to
   ```lua
   MMapPlus = {}
   ```
   That's it — makes it a global. Once that's live, `SmartMinimapAuto` can
   call `mapOverlayGenerator:generateGrowthStateOverlay(callback, allGrowthStates, yourFruitSet)`
   directly and set `MMapPlus.overlay = handle` itself, giving a real
   "only fields growing beets/carrots" view. I didn't make this edit for
   you automatically — it's someone else's mod file, and whether to patch
   a third-party mod's source is worth deciding deliberately rather than
   me doing it silently. Say the word and I'll wire it up properly with the
   global exposed.

## Behavior notes
- Auto-switch only fires on entering/leaving a vehicle — it won't fight you
  if you manually cycle overlays with Alt+9 mid-session.
- Leaving any vehicle resets the overlay to `FIELDS` (MinimapPlus's neutral
  "no overlay" state).
- `SOWING` is intentionally left unmapped — there's no built-in "ready to
  sow" overlay in MinimapPlus to hook into. Worth a discovery-style dig if
  you want it later (possibly derivable as "tilled but not `CROPS`-flagged"
  by combining two overlays, but that's genuinely new logic, not something
  already sitting there like the others).

## Click a field on the big map

Every field has a small **"i"** at its corner on the big map (the job letters, where there are any, sit to its right), and a click **anywhere inside the field's polygon** does the same as a click on the
"i": a popup about **that field** - "Field 7", its size (from WAILA's own traced polygon), what grows there ("Wheat, growing"), and **Visit**, which takes you to a point inside the field. Nothing else: no Sell
and no Tag place, no farmland highlight.

Why not the farmland popup: the buyable original farmlands and the fields a map has once it was changed afterwards have no relation, so a farmland's name, size and price say nothing about the field
(and Sell would sell the farmland). The game's farmland popup is only the host (it is the one with a Visit button); everything in it is replaced. If anything does not fit, the map behaves as before and
the log says `[TaskMap] field click: ...`.

The labels used to be unclickable: a hotspot without a click area gets no mouse events at all (the farmland tags have one). The "i" has a round one, as large as the farmland tag's is.

Test: `lua5.1 tests/field_click_test.lua` (a fake map frame, 23 checks).

### Where the "i" goes

**Move it yourself.** On the big map, **right click** an "i" and it hangs on the cursor (it follows the cursor inside its own field, and stays at the last spot inside when the cursor leaves it). A **left click** puts it down there, and the position is kept for that savegame (`modSettings/FS25_TaskMap/markers_<savegame>.xml`); a **right click** while carrying puts it back where it was. A redraw of the markers (a field plowed, a vehicle leaving a field) does not drop it: the carry passes to the field's new marker and goes on; only closing the map puts it back. **Shift + right click** an "i" takes it back to the automatic position, and so does **Reset label**, the button under Visit in the field's popup: the field is traced again from the ground as it is now (WAILA), the "i"s of pieces that lie inside the new outline are merged into it, and the label is worked out again for the fresh outline. Use it when an "i" hardly moves (its field outline is old) or a plowed field shows two of them. The saved point belongs to whichever field's outline contains it, so it survives the field being traced again; if the field is reshaped so the point falls outside, the automatic position is used. Test: `lua5.1 tests/marker_move_test.lua`.

Not on top of the game's farmland number tags: each field's "i" (and its job letters) is put inside the field's polygon, away from every tag (they sit at the farmland's own spot), away from the field's own edge,
and near its old position when that is a tie (`LabelPlacement.lua`, tested). It is worked out once per field and kept, a few fields per redraw, so it costs nothing; a field not worked out yet keeps its old spot
for a moment. Test: `lua5.1 tests/label_placement_test.lua` (8 checks).

**One "i" per field.** Ground that is plowed bit by bit is first registered by WAILA as fields of its own (pieces), until a later trace merges them, and each piece used to get an "i". An entry whose sample point lies inside the outline of a bigger entry (of equal ones the lower id) is now left out of the redraw (`LabelPlacement.coveredEntries`: a point-in-polygon test per redraw, no scanning). Test: `lua tests/label_placement_test.lua`.
