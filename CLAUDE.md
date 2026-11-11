# QuestieGamepad (repo: wow-forever-questie-gamepad)

A standalone WoW addon that makes Blizzard's "Access Quest Tracker" controller shortcut (LB + RB + D-pad Up)
focus the [Questie](https://github.com/Questie/Questie) tracker on **World of Warcraft: Forever** (the native
gamepad UI). Without it the shortcut silently does nothing because Questie hides `ObjectiveTrackerFrame`.

Written against Questie **12.6.5** (`X-BUILD-COMMIT: 0214175640abba697f535b2be73787a4c2f2b32b`),
Forever client 1.60.1 (Interface 16001), 2026-11-11. Not yet confirmed in game at the time of writing;
update this line when it is.

It began as a patch to Questie's own files (first commit in the git history); that form is retired.

## Layout

- `QuestieGamepad/QuestieGamepad.toc` — Interface 16001, `## Dependencies: Questie`.
- `QuestieGamepad/QuestieGamepad.lua` — all the logic.
- `Makefile` — `make install` symlinks `QuestieGamepad/` into
  `/Applications/World of Warcraft/_forever_/Interface/AddOns` (override with `WOW_ADDONS=`), so edits apply on
  `/reload`; `make uninstall` removes the link; `make check` syntax-checks the Lua with `luajit` (Homebrew).

## How the addon attaches to Questie

- No Questie file is edited. It reaches Questie through the global `QuestieLoader:ImportModule(...)`
  (`QuestieTracker`, `TrackerLinePool`, `TrackerFadeTicker`, `AchievementTracking`, `TrackerRecipes`,
  `QuestieCombatQueue`, `l10n`) and never calls `CreateModule`.
- Frames, events and hooks are set up at file load. Questie's files have already run by then (it is a
  dependency), so `TrackerLinePool.RefreshHighlight` exists to hook. Questie starts its tracker later, from a
  coroutine after login, or never when the tracker is disabled; everything that touches the tracker first checks
  `QuestieTracker.started`, and the tracker frame is read lazily as the global `Questie_BaseFrame` (named in
  Questie's `Modules/Tracker/TrackerBaseFrame.lua`). A tracker enabled later just works.
- Its own strings (`Collapse`, `Expand`, `Untrack Recipe`, `Use Quest Item`, `Back`, the two error messages) are
  plain English. A local `l10n()` wrapper asks Questie only for keys present in `l10n.translations`
  (`Focus Quest`, `Unfocus`, `Untrack Quest`, `Untrack Achievement`), because Questie logs an error per call for
  unknown keys when its debug mode is on.
- Its frames are named `QuestieGamepad_*`.
- It returns at the top if `QuestieLoader._modules["TrackerGamepad"].Initialize` exists, i.e. a Questie that
  still carries the retired patch, so the two never double-hook. That check must stay before the first
  `ImportModule`, which creates any module it is asked for.
- Taint shows up as `QuestieGamepad` in `taint.log`.

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
  so the addon re-hooks from a `hooksecurefunc(bar, "SetUpDpadTop", ...)`.
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
  panel's button groups when a frame is created inside it, so the addon creates all its frames with
  `UIParent` as parent, at file load.

Questie side (what the addon relies on):

- `TrackerLinePool.GetHighestIndex()` / `GetLine(i)` iterate the drawn lines. Navigable lines have
  `line.mode` of `"zone"`, `"quest"` (quests *and* recipes; recipes have `line.Recipe`, quests `line.Quest`)
  or `"achieve"`. Objective lines (`"objective"`) are skipped, like Blizzard's tracker.
- Per-line buttons: `line.expandZone` (zone collapse, uses OnMouseDown/OnMouseUp scripts, `.mode` 1 = expanded,
  `.zoneId`), `line.expandQuest` (quest collapse, OnClick, `.mode` 1 = expanded), `line.questFocus`
  (OnClick toggles Questie focus / Blizzard super-track; hidden when the option is off or the quest can't be focused).
- Quest item buttons are `Questie_ItemButton<n>`, `SecureActionButtonTemplate` with `item1` attribute, parented to
  the title line only while shown (collapsed quests move them back to UIParent). The addon finds them via
  `line:GetChildren()` and binds d-pad Right straight to the button name; Blizzard's `SecureActionButton_OnClick`
  runs the action on exactly one of key-down/key-up per the `ActionButtonUseKeyDown` cvar.
- `TrackerLinePool.OnHighlightEnter(line or line.expandZone)` / `OnHighlightLeave()` are the hover dim/undim.
  Every `QuestieTracker:Update()` ends with `TrackerLinePool.RefreshHighlight()`, which resets it; the addon
  hooks that with `hooksecurefunc` to re-select after each redraw (lines are pooled and reused for other entries,
  so selection is tracked by an identity key `mode:id`, not by line object).
- Untrack paths: `QuestieTracker:UntrackQuestId(id)`, `AchievementTracking.Untrack(id)` (+ queued `Update`),
  `TrackerRecipes.Untrack(id)`. `QuestieCombatQueue:Queue(fn)` defers UI work out of combat.
- `TrackerUtils:ShowQuestLog` is deliberately not used: opening the quest log from addon code taints the
  gamepad UI (Questie already prints a message instead under the controller UI).

Behaviour summary: post-hook the shortcut button (only acts when `ObjectiveTrackerFrame` is hidden);
on activation take d-pad + A/B/X/Y with `SetOverrideBindingClick(bindingOwner, true, ...)` to its own named
buttons; highlight frame + prompt footer (glyphs via `InputIconTextureSetUtility.GetNormalActiveInputIconButtonTexture`,
wrapped in pcall with a text fallback); 0.05 s OnUpdate poll keeps the selection valid; deactivate on B, on
`PLAYER_REGEN_DISABLED`, when `isUIFocused`/SmartNavigation shows, when the tracker empties, or when an override
binding on one of our keys is set by an owner other than `UIParent` (another addon's controller navigation such as
BaganatorGamepad — it keeps the keys). Blizzard rebinding one of our keys (owner `UIParent`) is re-asserted next frame.
Controls: Up/Down move; A focus/unfocus quest or collapse/expand zone (falls back to collapse/expand quest when the
focus button is hidden); X collapse/expand quest; Y untrack; Right use quest item; B leave; LB+RB+Up again = first entry.

Quest log fallback (no tracker to navigate: Questie tracker disabled, hidden, minimized or empty):

- The shortcut button's handler does nothing in that state, and the addon must not call `ToggleQuestLog()` /
  `ToggleWorldMap()` itself (taint, see above). Instead it hooks the shortcuts bar's `OnShow`/`OnHide` (the bar
  is shown exactly while LB + RB are held, `StaticOverrideActionBarMixin:ActivateOverrideBar`) and, while the bar
  is up and there is nothing to navigate, binds the shortcut key to Blizzard's `TOGGLEQUESTLOG` binding with
  `SetOverrideBinding(fallbackOwner, true, key, "TOGGLEQUESTLOG")`. The client runs binding commands untainted.
  On Forever `ToggleQuestLog` opens `QuestMapFrame` on the world map (`Blizzard_UIPanels_Game/Mainline/QuestMapFrame.lua`
  with Camelot overrides; binding defined in `Blizzard_FrameXML/Bindings_Camelot.xml`).
- The key comes from `GetBindingKey("GAMEPADACTIONBUTTON2")` (falls back to `PADDUP`): gamepad keys run the
  `GAMEPADACTIONBUTTON<n>` bindings in `Blizzard_GamepadActionBars/Bindings.xml`, which press button n of the
  active bar; 2 is d-pad up, and the shortcuts bar has no d-pad/face swap cvar. `CTRL-SHIFT-<key>` is bound too.
- Not armed in combat (bindings are locked) or while the navigation is active; disarmed on bar hide and on
  `PLAYER_REGEN_DISABLED`; re-armed next frame if Blizzard (owner `UIParent`) rebinds the key while the bar is up.
- Known gap: the Blizzard button's handler also calls `GamepadTargetLogic:ConsumeModifier()`, which the fallback
  skips (calling it from addon code would taint `wasModifierUsed`). If releasing LB/RB after the fallback
  tab-targets something, that is why (`Blizzard_GamepadTargeting/TargetLogic.lua`, `EndTargeting`).

## After a Questie update

Nothing needs re-applying. If something breaks, re-check the Questie APIs the addon touches, from inside the
Questie addon folder:

- `grep -n "GetHighestIndex\|function TrackerLinePool.GetLine\|RefreshHighlight\|OnHighlightEnter" Modules/Tracker/LinePool/TrackerLinePool.lua`
- `grep -n 'SetMode("' Modules/Tracker/LinePool/LineBuilder.lua` (line modes still zone/quest/achieve/objective?)
- `grep -n "expandQuest\|questFocus\|expandZone" Modules/Tracker/LinePool/TrackerLine.lua`
- `grep -n "Questie_ItemButton\|item1" Modules/Tracker/LinePool/TrackerLinePool.lua Modules/Tracker/LinePool/TrackerItemButton.lua`
- `grep -n "function QuestieTracker:UntrackQuestId\|function AchievementTracking.Untrack\|function TrackerRecipes.Untrack" -r Modules/Tracker`
- `grep -n "Questie_BaseFrame" Modules/Tracker/TrackerBaseFrame.lua` and `grep -n "QuestieTracker.started = true" Modules/Tracker/QuestieTracker.lua`
- `grep -n "function QuestieLoader:ImportModule\|_modules" Modules/Libs/QuestieLoader.lua`

Also check whether upstream added its own controller support
(`grep -rn "InputUtil\|GamepadMode\|ShortcutsActionBar" Modules`); if Questie focuses its tracker itself, this
addon should be retired.

Then `make check`, update the version/commit line at the top of this file, `/reload`, and test (see below).

If the Blizzard side changed (shortcut stops triggering, bindings fight): re-clone the `forever` branch of
`Gethe/wow-ui-source` (sparse, see above) and re-check `ShortcutsActionBar.lua`, `StaticOverrideActionBar.lua`
(`dpadTopButton`, `SetUpDpadTop`), `FrameControlsManager.lua` (`isUIFocused`) and `InputButtonBinding.lua` (owner `UIParent`).
Bump `## Interface:` in the TOC when the client's interface number changes.

## Testing in game

- Controller UI on, Questie tracker enabled with at least one tracked quest. Press LB+RB+Up: a gold border appears on
  the first zone header, the other entries dim, a prompt footer shows under (or above) the tracker.
- Move, press A on a quest title (focus toggles, map icons fade), X (collapses), Y on a throwaway quest (untracks,
  highlight moves to the next entry), Right on a quest with an item, B (everything restored, d-pad back to normal).
- Quest log fallback: minimize or hide the Questie tracker (or untrack everything), press LB+RB+Up: the world map
  opens with the quest log. Releasing LB/RB must not change target. In combat nothing happens.
- Taint check: `/console taintLog 2` before reproducing, then look for `QuestieGamepad` or `Questie` lines in `Logs/taint.log`
  (client folder). Any "blocked from an action only available to the Blizzard UI" popup is a failure.
- Also check: open the world map with the controller while the tracker is focused (focus must drop cleanly),
  enter combat (keys released before lockdown), open bags with BaganatorGamepad installed (bags keep the keys).

## Related local addons

`/Applications/World of Warcraft/_forever_/Interface/AddOns/BaganatorGamepad/BaganatorGamepad.lua` is the model this
follows (override bindings + own highlight, re-assert on foreign rebinding). Do not use the `Baganator` addon's own
source as reference; its AGENTS.md forbids it.
