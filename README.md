# QuestieGamepad

A World of Warcraft: Forever addon that makes the "Access Quest Tracker" controller shortcut
(LB + RB + D-pad Up) work with the [Questie](https://github.com/Questie/Questie) tracker under Blizzard's
native gamepad UI.

Blizzard's shortcut only focuses its own `ObjectiveTrackerFrame`, which Questie hides, so with Questie
installed it does nothing. QuestieGamepad takes over the d-pad and face buttons while the Questie tracker is
focused, without handing Questie's frames to Blizzard's SmartNavigation (which would taint the gamepad UI and
trigger blocked-action popups).

It is a separate addon that depends on Questie and changes nothing inside it, so it survives Questie updates.

## Install

Copy or symlink the `QuestieGamepad` folder into the Forever AddOns directory:

```
World of Warcraft/_forever_/Interface/AddOns/QuestieGamepad
```

On macOS with the game in the default location, `make install` creates the symlink for you
(`make install WOW_ADDONS=<AddOnsDir>` for another location). `make uninstall` removes it. Restart the client
after the first install, then make sure "Questie Gamepad" is enabled in the addon list.

## Controls while the tracker is focused

| Button | Action |
| --- | --- |
| D-pad Up / Down | Move between zone headers and quest titles |
| A / Cross | Focus or unfocus the quest; collapse or expand a zone header |
| X / Square | Collapse or expand the quest |
| Y / Triangle | Untrack the quest, achievement or recipe |
| D-pad Right | Use the quest item |
| B / Circle | Leave the tracker |

When there is no Questie tracker to focus (disabled, hidden, minimized or empty), the shortcut opens the quest
log on the world map instead (out of combat only).

Focus is also released when combat starts, when a Blizzard window takes controller focus, or when another
addon's controller navigation (e.g. BaganatorGamepad with bags open) owns the keys.

See `CLAUDE.md` for how it works and what to re-check after Questie or client updates.
