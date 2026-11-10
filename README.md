# questie-gamepad-patch

Makes WoW: Forever's "Access Quest Tracker" controller shortcut (LB + RB + D-pad Up) work with the
[Questie](https://github.com/Questie/Questie) tracker under Blizzard's native gamepad UI.

Blizzard's shortcut only focuses its own `ObjectiveTrackerFrame`, which Questie hides, so with Questie
installed it did nothing. The patch adds a `TrackerGamepad` module that takes over the d-pad and face
buttons while the Questie tracker is focused, without handing Questie's frames to Blizzard's
SmartNavigation (which would taint the gamepad UI and trigger blocked-action popups).

## Apply

```sh
scripts/apply.sh "/Applications/World of Warcraft/_forever_/Interface/AddOns/Questie"
```

then `/reload` in game. Revert with `scripts/apply.sh "<QuestieDir>" -R`. Re-apply after every Questie update.

## Controls while the tracker is focused

| Button | Action |
| --- | --- |
| D-pad Up / Down | Move between zone headers and quest titles |
| A / Cross | Focus or unfocus the quest; collapse or expand a zone header |
| X / Square | Collapse or expand the quest |
| Y / Triangle | Untrack the quest, achievement or recipe |
| D-pad Right | Use the quest item |
| B / Circle | Leave the tracker |

Focus is also released when combat starts, when a Blizzard window takes controller focus, or when another
addon's controller navigation (e.g. BaganatorGamepad with bags open) owns the keys.

See `CLAUDE.md` for how it works and how to update it for new Questie versions.
