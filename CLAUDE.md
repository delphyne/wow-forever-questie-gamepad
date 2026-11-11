# questie-gamepad-patch

A patch for the [Questie](https://github.com/Questie/Questie) WoW addon that makes Blizzard's
"Access Quest Tracker" controller shortcut (LB + RB + D-pad Up) focus Questie's tracker on
**World of Warcraft: Forever** (the native gamepad UI). Without it the shortcut silently does nothing
because Questie hides `ObjectiveTrackerFrame`.

Written against Questie **12.6.5** (`X-BUILD-COMMIT: 0214175640abba697f535b2be73787a4c2f2b32b`),
Forever client 1.60.1 (Interface 16001), 2026-11-10. Not yet confirmed in game at the time of writing;
update this line when it is.

## Layout

- `questie-forever-gamepad-tracker.patch` — the deliverable. Unified diff with `a/` and `b/` prefixes,
  paths relative to the Questie addon folder. Apply with `patch -p1` or `git apply` from inside that folder.
- `files/Modules/Tracker/TrackerGamepad.lua` — a plain copy of the new module (the bulk of the patch),
  kept so it can be edited and diffed without extracting it from the patch.
- `scripts/apply.sh [QuestieDir] [-R]` — dry-runs then applies (or reverts with `-R`) to the live install
  at `/Applications/World of Warcraft/_forever_/Interface/AddOns/Questie` by default.
- `QuestieGamepad/` — the same feature as a standalone addon (see below). `make install` symlinks it into the AddOns folder (`make uninstall`, `make check`).
- `scripts/make-patch.sh <pristine> <patched>` — rebuilds the patch and the `files/` copy from two Questie folders.

## Standalone addon (`QuestieGamepad/`)

The same logic as a separate addon (`QuestieGamepad.toc`, Interface 16001, `## Dependencies: Questie`, plus
`QuestieGamepad.lua`), symlinked into the AddOns folder with `make install` (override `WOW_ADDONS=` for another location). Not yet confirmed in game.
It is `files/Modules/Tracker/TrackerGamepad.lua` with these differences; keep the two in step when changing either:

- No Questie file is edited. It reaches Questie through the global `QuestieLoader:ImportModule(...)` and never
  calls `CreateModule`.
- No `Initialize(baseFrame)` call from `QuestieTracker.Initialize`: frames, events and hooks are set up at file
  load (Questie's files have already run, so `TrackerLinePool.RefreshHighlight` exists to hook), and the tracker
  frame is read lazily as the global `Questie_BaseFrame` (named in `TrackerBaseFrame.lua`). Everything that
  touches the tracker first checks `QuestieTracker.started`, so a tracker enabled later just works.
- Its own strings are plain English; a local `l10n()` wrapper only asks Questie for keys present in
  `l10n.translations` (unknown keys log an error per call under Questie's debug mode).
- Frames are named `QuestieGamepad_*` instead of `Questie_TrackerGamepad*`.
- It returns at the top if `QuestieLoader._modules["TrackerGamepad"].Initialize` exists, i.e. Questie still
  carries the patch, so the two never double-hook. That check must stay before the first `ImportModule`.
- Taint is attributed to `QuestieGamepad` rather than `Questie` in `taint.log`; the taint rule below is unchanged.

For a new Questie release there is nothing to re-apply; just re-run the API greps in "Updating the patch" step 3
(plus `grep -n Questie_BaseFrame Modules/Tracker/TrackerBaseFrame.lua`).

## What the patch changes (5 files)

1. **New** `Modules/Tracker/TrackerGamepad.lua` — all the logic.
2. `Questie_Forever.toc` and `Questie_Camelot.toc` — add `Modules\Tracker\TrackerGamepad.lua` right after
   `Modules\Tracker\LinePool\LineBuilder.lua`. Both TOCs are Interface 16001 (Forever's game type is
   "camelot"); the other flavors (Vanilla/TBC/Wrath/Mists) are not touched.
3. `Modules/Tracker/QuestieTracker.lua` — import the module next to the other tracker imports
   (after `ChallengeModeTimer`) and call `TrackerGamepad.Initialize(trackerBaseFrame)` inside
   `QuestieTracker.Initialize`, guarded by `if Questie.IsForever then`, after
   `TrackerFadeTicker.Initialize(...)` and before `QuestieTracker.started = true`.
4. `Localization/Translations/TrackerUI.lua` — seven enUS-only keys appended at the end of the table:
   `Collapse`, `Expand`, `Untrack Recipe`, `Use Quest Item`, `Back`,
   `Can't navigate the Questie tracker in combat.`, `The Questie tracker has nothing to navigate.`
   Questie's `l10n()` returns the key when a locale entry is missing, so enUS-only is fine.

## How it works (read this before changing anything)

Blizzard side (source: GitHub `Gethe/wow-ui-source`, branch `forever`, sparse-clone
`Interface/AddOns/Blizzard_GamepadActionBars`, `Blizzard_GamepadSharedUtility`,
`Blizzard_GamepadSmartNavigation`, `Blizzard_ObjectiveTracker`, `Blizzard_SharedXML`):

- The shortcut is `GamepadShortcutsActionBarMixin:SetUpDpadTop` in
  `Blizzard_GamepadActionBars/TargetActionBars/ShortcutsActionBar.lua`. Its handler is
  `if ObjectiveTrackerFrame:IsShown() then GamepadMode.FrameControlsManager:FrameShown(ObjectiveTrackerFrame) end`.
  The button is `GamepadMainActionBarFrame.PageUnit.ShortcutsActionBar.dpadTopButton` (follows the action
  even when the d-pad/face swap cvar is on). `StaticOverrideActionBarMixin:SetUpActionButtons` re-sets every
  button's OnClick with `SetScript` (which drops `HookScript` hooks) and then calls `SetUpDpadTop` again,
  so the module re-hooks from a `hooksecurefunc(bar, "SetUpDpadTop", ...)`.
- LB/RB are the gamepad modifiers `SHIFT`/`CTRL`; key names are `PAD1..PAD4` (A/B/X/Y = bottom/right/left/top)
  and `PADDUP/PADDDOWN/PADDLEFT/PADDRIGHT`. Constants `GAMEPAD_FACE_BOTTOM` etc. live in
  `Blizzard_SharedXML/Shared/GamepadConstants.lua`.
- Every Blizzard gamepad binding is `SetOverrideBinding*(UIParent, true, key, ...)` through
  `InputBindingManager` and is re-applied whenever its binding stack changes (e.g. releasing LB+RB).
- `GamepadMode.FrameControlsManager.isUIFocused` is true while a Blizzard frame has controller focus;
  `SmartNavigation:IsShown()` is true while its cursor is on a panel.
- **Taint rule:** never hand a Questie frame to `FrameControlsManager:FrameShown` or `SmartNavigation`.
  SmartNavigation hooks the frame's OnHide and walks its buttons from secure code; Questie hides/rebuilds its
  tracker from addon code, so the gamepad state becomes tainted by "Questie" and
  `SetPreferredGamepadInteractTarget()` gets blocked in a popup loop (Questie issue #7968 is the same failure
  from opening the quest log). SmartNavigation also hooks global `CreateFrame` and rebuilds the open Blizzard
  panel's button groups when a frame is created inside it, so the module creates all its frames with
  `UIParent` as parent, at init.

Questie side (what the module relies on):

- `TrackerLinePool.GetHighestIndex()` / `GetLine(i)` iterate the drawn lines. Navigable lines have
  `line.mode` of `"zone"`, `"quest"` (quests *and* recipes; recipes have `line.Recipe`, quests `line.Quest`)
  or `"achieve"`. Objective lines (`"objective"`) are skipped, like Blizzard's tracker.
- Per-line buttons: `line.expandZone` (zone collapse, uses OnMouseDown/OnMouseUp scripts, `.mode` 1 = expanded,
  `.zoneId`), `line.expandQuest` (quest collapse, OnClick, `.mode` 1 = expanded), `line.questFocus`
  (OnClick toggles Questie focus / Blizzard super-track; hidden when the option is off or the quest can't be focused).
- Quest item buttons are `Questie_ItemButton<n>`, `SecureActionButtonTemplate` with `item1` attribute, parented to
  the title line only while shown (collapsed quests move them back to UIParent). The module finds them via
  `line:GetChildren()` and binds d-pad Right straight to the button name; Blizzard's `SecureActionButton_OnClick`
  runs the action on exactly one of key-down/key-up per the `ActionButtonUseKeyDown` cvar.
- `TrackerLinePool.OnHighlightEnter(line or line.expandZone)` / `OnHighlightLeave()` are the hover dim/undim.
  Every `QuestieTracker:Update()` ends with `TrackerLinePool.RefreshHighlight()`, which resets it; the module
  hooks that with `hooksecurefunc` to re-select after each redraw (lines are pooled and reused for other entries,
  so selection is tracked by an identity key `mode:id`, not by line object).
- Untrack paths: `QuestieTracker:UntrackQuestId(id)`, `AchievementTracking.Untrack(id)` (+ queued `Update`),
  `TrackerRecipes.Untrack(id)`. `QuestieCombatQueue:Queue(fn)` defers UI work out of combat.
- `TrackerUtils:ShowQuestLog` is deliberately not used: opening the quest log from addon code taints the
  gamepad UI (Questie already prints a message instead under the controller UI).

Module behaviour summary: post-hook the shortcut button (only acts when `ObjectiveTrackerFrame` is hidden);
on activation take d-pad + A/B/X/Y with `SetOverrideBindingClick(bindingOwner, true, ...)` to its own named
buttons; highlight frame + prompt footer (glyphs via `InputIconTextureSetUtility.GetNormalActiveInputIconButtonTexture`,
wrapped in pcall with a text fallback); 0.05 s OnUpdate poll keeps the selection valid; deactivate on B, on
`PLAYER_REGEN_DISABLED`, when `isUIFocused`/SmartNavigation shows, when the tracker empties, or when an override
binding on one of our keys is set by an owner other than `UIParent` (another addon's controller navigation such as
BaganatorGamepad — it keeps the keys). Blizzard rebinding one of our keys (owner `UIParent`) is re-asserted next frame.
Controls: Up/Down move; A focus/unfocus quest or collapse/expand zone (falls back to collapse/expand quest when the
focus button is hidden); X collapse/expand quest; Y untrack; Right use quest item; B leave; LB+RB+Up again = first entry.

## Updating the patch for a new Questie release

1. Get the new Questie (CurseForge zip or the git tag) into a pristine folder, e.g. `/tmp/questie-pristine/Questie`.
2. Try `cd <pristine copy> && patch -p1 --dry-run < questie-forever-gamepad-tracker.patch`. The TOC and
   translation hunks are context-sensitive but small; `QuestieTracker.lua` has two hunks (import block, Initialize).
3. If a hunk fails, re-make the three small edits by hand following "What the patch changes" above, drop in
   `files/Modules/Tracker/TrackerGamepad.lua`, then re-check the Questie APIs the module touches:
   - `grep -n "GetHighestIndex\|function TrackerLinePool.GetLine\|RefreshHighlight\|OnHighlightEnter" Modules/Tracker/LinePool/TrackerLinePool.lua`
   - `grep -n 'SetMode("' Modules/Tracker/LinePool/LineBuilder.lua` (line modes still zone/quest/achieve/objective?)
   - `grep -n "expandQuest\|questFocus\|expandZone" Modules/Tracker/LinePool/TrackerLine.lua`
   - `grep -n "Questie_ItemButton\|item1" Modules/Tracker/LinePool/TrackerLinePool.lua Modules/Tracker/LinePool/TrackerItemButton.lua`
   - `grep -n "function QuestieTracker:UntrackQuestId\|function AchievementTracking.Untrack\|function TrackerRecipes.Untrack" -r Modules/Tracker`
   - `grep -n "TrackerFadeTicker.Initialize\|QuestieTracker.started = true" Modules/Tracker/QuestieTracker.lua`
   - `grep -n "GamepadMapHover" *.toc` shows which TOCs are the Forever flavors (currently Forever + Camelot).
   Also check whether upstream added its own controller support (`grep -rn "InputUtil\|GamepadMode\|ShortcutsActionBar" Modules`);
   if Questie focuses its tracker itself, this patch should be retired.
4. Syntax check: `luajit -bl Modules/Tracker/TrackerGamepad.lua > /dev/null` (luajit from Homebrew).
5. Rebuild: `scripts/make-patch.sh /tmp/questie-pristine/Questie <patched folder>`; it also refreshes `files/`.
6. Update the version/commit line at the top of this file, apply to the live install with `scripts/apply.sh`,
   `/reload`, and test (see below).

If the Blizzard side changed (shortcut stops triggering, bindings fight): re-clone the `forever` branch of
`Gethe/wow-ui-source` (sparse, see above) and re-check `ShortcutsActionBar.lua`, `StaticOverrideActionBar.lua`
(`dpadTopButton`, `SetUpDpadTop`), `FrameControlsManager.lua` (`isUIFocused`) and `InputButtonBinding.lua` (owner `UIParent`).

## Testing in game

- Controller UI on, Questie tracker enabled with at least one tracked quest. Press LB+RB+Up: a gold border appears on
  the first zone header, the other entries dim, a prompt footer shows under (or above) the tracker.
- Move, press A on a quest title (focus toggles, map icons fade), X (collapses), Y on a throwaway quest (untracks,
  highlight moves to the next entry), Right on a quest with an item, B (everything restored, d-pad back to normal).
- Taint check: `/console taintLog 2` before reproducing, then look for `Questie` lines in `Logs/taint.log`
  (client folder). Any "blocked from an action only available to the Blizzard UI" popup is a failure.
- Also check: open the world map with the controller while the tracker is focused (focus must drop cleanly),
  enter combat (keys released before lockdown), open bags with BaganatorGamepad installed (bags keep the keys).

## Reverting

`scripts/apply.sh "<QuestieDir>" -R`, or delete `Modules/Tracker/TrackerGamepad.lua` and undo the three edits.
Reinstalling Questie from CurseForge also wipes it (the patch must be re-applied after every Questie update).

## Related local addons

`/Applications/World of Warcraft/_forever_/Interface/AddOns/BaganatorGamepad/BaganatorGamepad.lua` is the model this
follows (override bindings + own highlight, re-assert on foreign rebinding). Do not use the `Baganator` addon's own
source as reference; its AGENTS.md forbids it.
