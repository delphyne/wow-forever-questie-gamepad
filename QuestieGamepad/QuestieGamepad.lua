-- QuestieGamepad: controller navigation of the Questie tracker, as a standalone addon.
-- Depends on Questie and reaches into its modules through the global QuestieLoader; nothing in Questie is modified.

if not (QuestieLoader and QuestieLoader.ImportModule) then
    return
end
-- A Questie that carries the old in-tree patch (Modules/Tracker/TrackerGamepad.lua) already does all of this.
-- Checked before importing anything, because ImportModule creates the modules it is asked for.
local patched = QuestieLoader._modules and QuestieLoader._modules["TrackerGamepad"]
if patched and patched.Initialize then
    return
end

local TrackerGamepad = {}

---@type QuestieTracker
local QuestieTracker = QuestieLoader:ImportModule("QuestieTracker")
---@type TrackerLinePool
local TrackerLinePool = QuestieLoader:ImportModule("TrackerLinePool")
---@type TrackerFadeTicker
local TrackerFadeTicker = QuestieLoader:ImportModule("TrackerFadeTicker")
---@type AchievementTracking
local AchievementTracking = QuestieLoader:ImportModule("AchievementTracking")
---@type TrackerRecipes
local TrackerRecipes = QuestieLoader:ImportModule("TrackerRecipes")
---@type QuestieCombatQueue
local QuestieCombatQueue = QuestieLoader:ImportModule("QuestieCombatQueue")
---@type l10n
local questieL10n = QuestieLoader:ImportModule("l10n")

---Questie's translation where it has one ("Focus Quest", "Untrack Quest", ...), the English text otherwise.
---Asking Questie for a key it does not know logs an error per call when its debug mode is on.
---@param text string
---@return string
local function l10n(text)
    if questieL10n.translations and questieL10n.translations[text] then
        return questieL10n(text)
    end
    return text
end

-- Controller navigation of the Questie tracker for Forever's native gamepad UI.
--
-- Blizzard's "Access Quest Tracker" shortcut (LB + RB + Up) is a button on the gamepad shortcuts action bar whose
-- handler only does something while ObjectiveTrackerFrame is shown: it hands the frame to Blizzard's
-- FrameControlsManager, which lets SmartNavigation walk the tracker's buttons. Questie hides ObjectiveTrackerFrame,
-- so with Questie the shortcut did nothing at all.
--
-- Questie's tracker can not simply be handed to FrameControlsManager instead. SmartNavigation hooks the OnHide of
-- every frame it manages and walks the frame's buttons from Blizzard's secure code. Questie shows, hides and
-- rebuilds its tracker from addon code, so those hooks would run tainted and leave the gamepad state tainted by
-- "Questie": blocked SetPreferredGamepadInteractTarget, broken controller bindings, blocked-action popups until a
-- /reload (see #7968 for the same effect from opening the quest log).
--
-- So Blizzard's gamepad code is kept out of it. The shortcut button gets a post-hook that only runs when
-- ObjectiveTrackerFrame is hidden, i.e. when Blizzard's own handler did nothing. While the navigation is active (and
-- out of combat) this addon takes the d-pad and face buttons with override bindings to its own buttons, moves its own
-- highlight between the zone headers and quest titles of the tracker and shows a prompt footer, and gives the keys
-- back on B, on combat, when a Blizzard frame takes gamepad focus or when the tracker goes away.

local KEYS = {
    up = GAMEPAD_DPAD_TOP or "PADDUP",
    down = GAMEPAD_DPAD_BOTTOM or "PADDDOWN",
    left = GAMEPAD_DPAD_LEFT or "PADDLEFT",
    right = GAMEPAD_DPAD_RIGHT or "PADDRIGHT",
    select = GAMEPAD_FACE_BOTTOM or "PAD1", -- A / Cross: focus a quest, collapse or expand a zone
    back = GAMEPAD_FACE_RIGHT or "PAD2",    -- B / Circle: leave the tracker
    toggle = GAMEPAD_FACE_LEFT or "PAD3",   -- X / Square: collapse or expand a quest
    untrack = GAMEPAD_FACE_TOP or "PAD4",   -- Y / Triangle: untrack
}

-- Only these lines take the highlight. Objectives have no action of their own, like Blizzard's tracker.
local NAVIGABLE_MODES = { zone = true, quest = true, achieve = true }

local UPDATE_INTERVAL = 0.05

local bindingOwner, fallbackOwner, highlight, footer, updateFrame, eventFrame
local navButtons = {}
local noopButton
local active = false
---@type TrackerLineFrame?
local selectedLine
---@type string? Identity of the selected line, which survives a redraw of the tracker
local selectedKey
---@type number? Position of the selected line among the navigable lines
local selectedIndex
---@type Button? The quest item button the d-pad right is bound to
local boundItemButton
local elapsedSinceUpdate = 0
local reassertPending = false
local shortcutHooked = false
---@type Frame? Blizzard's shortcuts action bar, shown while LB + RB are held
local shortcutBar
---The shortcut key opens the quest log instead, because there is no tracker to navigate
local fallbackArmed = false
local fallbackKeys = {}
local fallbackReassertPending = false
---Set by a tracker redraw, which reuses the lines and resets the hover highlight
local redrawn = false

local OUR_KEYS = {}
for _, key in pairs(KEYS) do
    OUR_KEYS[key] = true
end

local function _IsGamepadUIEnabled()
    return InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled()
end

---@return boolean
local function _IsAvailable()
    return QuestieTracker.started == true and Questie.db.profile.trackerEnabled and _IsGamepadUIEnabled()
end

---A Blizzard frame has the gamepad focus. Its d-pad and face buttons must not be taken from it.
---@return boolean
local function _IsBlizzardUIFocused()
    local manager = GamepadMode and GamepadMode.FrameControlsManager
    if manager and manager.isUIFocused then
        return true
    end
    return SmartNavigation ~= nil and SmartNavigation:IsShown()
end

---@return TrackerLineFrame[]
local function _GetLines()
    local lines = {}
    for i = 1, TrackerLinePool.GetHighestIndex() do
        local line = TrackerLinePool.GetLine(i)
        if line and NAVIGABLE_MODES[line.mode] and line:IsVisible() then
            lines[#lines + 1] = line
        end
    end
    return lines
end

---@param line TrackerLineFrame
---@return string?
local function _GetLineKey(line)
    if line.mode == "zone" then
        return "zone:" .. tostring(line.expandZone and line.expandZone.zoneId)
    elseif line.Recipe then
        return "recipe:" .. tostring(line.Recipe.Id)
    elseif line.Quest then
        return line.mode .. ":" .. tostring(line.Quest.Id)
    end
    return nil
end

---@param lines TrackerLineFrame[]
---@param key string?
---@return TrackerLineFrame?, number?
local function _FindLineByKey(lines, key)
    if not key then
        return nil, nil
    end
    for index, line in ipairs(lines) do
        if _GetLineKey(line) == key then
            return line, index
        end
    end
    return nil, nil
end

---Quest item buttons are only parented to a line while they are shown on it.
---@param line TrackerLineFrame
---@return Button?
local function _GetItemButton(line)
    if line.mode == "zone" then
        return nil
    end
    for _, child in ipairs({ line:GetChildren() }) do
        if child.itemId and child:IsShown() and child.GetAttribute and child:GetAttribute("item1") then
            return child
        end
    end
    return nil
end

---@param key string
---@return string
local function _GetKeyMarkup(key)
    -- Blizzard's lookup only reads its icon tables; it is safe to call from addon code
    local ok, atlas = pcall(function()
        return InputIconTextureSetUtility and InputIconTextureSetUtility.GetNormalActiveInputIconButtonTexture(key)
    end)
    if ok and type(atlas) == "string" and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        return CreateAtlasMarkup(atlas, 18, 18)
    end
    return "[" .. (_G["KEY_" .. key] or key) .. "]"
end

---@param line TrackerLineFrame
---@return string
local function _BuildPrompts(line)
    local prompts = {}
    local function add(key, label)
        prompts[#prompts + 1] = _GetKeyMarkup(key) .. " " .. label
    end

    if line.mode == "zone" then
        add(KEYS.select, line.expandZone.mode == 1 and l10n("Collapse") or l10n("Expand"))
    else
        local expandLabel = line.expandQuest.mode == 1 and l10n("Collapse") or l10n("Expand")
        if line.questFocus:IsShown() then
            local focused = line.Quest and Questie.db.char.TrackerFocus == line.Quest.Id
            add(KEYS.select, focused and l10n("Unfocus") or l10n("Focus Quest"))
            if line.expandQuest:IsShown() then
                add(KEYS.toggle, expandLabel)
            end
        elseif line.expandQuest:IsShown() then
            add(KEYS.select, expandLabel)
        end
        if line.Recipe then
            add(KEYS.untrack, l10n("Untrack Recipe"))
        elseif line.mode == "achieve" then
            add(KEYS.untrack, l10n("Untrack Achievement"))
        elseif line.Quest then
            add(KEYS.untrack, l10n("Untrack Quest"))
        end
        if _GetItemButton(line) then
            add(KEYS.right, l10n("Use Quest Item"))
        end
    end
    add(KEYS.back, BACK or l10n("Back"))

    return table.concat(prompts, "    ")
end

local function _UpdateFooter()
    -- Created by Questie when its tracker starts, which can be long after login (or never, with the tracker off)
    local baseFrame = Questie_BaseFrame
    if not (selectedLine and baseFrame) then
        footer:Hide()
        return
    end
    footer.text:SetText(_BuildPrompts(selectedLine))
    footer:SetWidth(footer.text:GetStringWidth() + 12)
    footer:ClearAllPoints()
    -- The prompts are usually wider than the tracker, which usually sits at the right edge of the screen: line the
    -- footer up with the tracker's left edge when it fits on screen from there, with its right edge otherwise.
    -- Both frames can be scaled differently, so compare in screen pixels.
    local side = "LEFT"
    local baseLeft = baseFrame:GetLeft()
    if baseLeft then
        local footerRight = baseLeft * baseFrame:GetEffectiveScale() + footer:GetWidth() * footer:GetEffectiveScale()
        if footerRight > UIParent:GetRight() * UIParent:GetEffectiveScale() then
            side = "RIGHT"
        end
    end
    -- Below the tracker unless the tracker sits at the bottom of the screen
    if (baseFrame:GetBottom() or 0) > footer:GetHeight() + 4 then
        footer:SetPoint("TOP" .. side, baseFrame, "BOTTOM" .. side, 0, -2)
    else
        footer:SetPoint("BOTTOM" .. side, baseFrame, "TOP" .. side, 0, 2)
    end
    footer:Show()
end

local function _ApplyBindings()
    if InCombatLockdown() then
        return
    end
    ClearOverrideBindings(bindingOwner)
    for name, button in pairs(navButtons) do
        SetOverrideBindingClick(bindingOwner, true, KEYS[name], button:GetName())
    end
    -- Keys without an action are still taken, so they do not fall through to the game while navigating
    SetOverrideBindingClick(bindingOwner, true, KEYS.left, noopButton:GetName())
    -- The quest item buttons are secure action buttons, so a binding click uses the item
    boundItemButton = selectedLine and _GetItemButton(selectedLine) or nil
    SetOverrideBindingClick(bindingOwner, true, KEYS.right, (boundItemButton or noopButton):GetName(), "LeftButton")
end

local function _Deselect()
    if selectedLine then
        TrackerLinePool.OnHighlightLeave()
    end
    selectedLine = nil
    highlight:Hide()
    footer:Hide()
end

---@param line TrackerLineFrame
---@param lines TrackerLineFrame[]?
local function _Select(line, lines)
    if selectedLine and selectedLine ~= line then
        TrackerLinePool.OnHighlightLeave()
    end
    selectedLine = line
    selectedKey = _GetLineKey(line)
    lines = lines or _GetLines()
    selectedIndex = nil
    for index, candidate in ipairs(lines) do
        if candidate == line then
            selectedIndex = index
            break
        end
    end

    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", line, "TOPLEFT", -3, 2)
    highlight:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 3, -1)
    highlight:Show()

    -- Highlights the entry like hovering it with the mouse; a zone header highlights its zone
    if line.mode == "zone" then
        TrackerLinePool.OnHighlightEnter(line.expandZone)
    else
        TrackerLinePool.OnHighlightEnter(line)
    end
    TrackerFadeTicker.Unfade()

    _UpdateFooter()
    _ApplyBindings()
end

function TrackerGamepad.Deactivate()
    if not active then
        return
    end
    active = false
    updateFrame:SetScript("OnUpdate", nil)
    _Deselect()
    if not InCombatLockdown() then
        ClearOverrideBindings(bindingOwner)
    end
end

---Keeps the highlight on the same entry across redraws and lets go when the tracker or the controller go away.
local function _Refresh()
    if not active then
        return
    end
    if InCombatLockdown() or (not _IsAvailable()) or _IsBlizzardUIFocused() then
        TrackerGamepad.Deactivate()
        return
    end

    local lines = _GetLines()
    if #lines == 0 then
        TrackerGamepad.Deactivate()
        return
    end

    local line = selectedLine
    if line and line:IsVisible() and NAVIGABLE_MODES[line.mode] and _GetLineKey(line) == selectedKey then
        -- Same entry on the same line; a redraw can still have moved its quest item button or reset the highlight
        if redrawn or _GetItemButton(line) ~= boundItemButton then
            _Select(line, lines)
        end
        redrawn = false
        return
    end

    -- The tracker was redrawn: follow the entry, or stay at the same position when it is gone
    redrawn = false
    local sameEntry = _FindLineByKey(lines, selectedKey)
    _Select(sameEntry or lines[math.min(selectedIndex or 1, #lines)], lines)
end

local function _OnUpdate(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < UPDATE_INTERVAL then
        return
    end
    elapsedSinceUpdate = 0
    _Refresh()
end

---@param step number 1 or -1
local function _Move(step)
    local lines = _GetLines()
    if #lines == 0 then
        return
    end
    local _, index = _FindLineByKey(lines, selectedKey)
    local target
    if index then
        target = lines[index + step]
    else
        target = lines[step > 0 and 1 or #lines]
    end
    if target then
        _Select(target, lines)
    end
end

---@param line TrackerLineFrame
local function _ToggleZone(line)
    local expandZone = line.expandZone
    local onMouseUp = expandZone:GetScript("OnMouseUp")
    if onMouseUp then
        onMouseUp(expandZone, "LeftButton")
    end
end

---@param line TrackerLineFrame
local function _ToggleQuest(line)
    if line.expandQuest:IsShown() then
        line.expandQuest:Click()
    end
end

local function _OnSelect()
    local line = selectedLine
    if not line then
        return
    end
    if line.mode == "zone" then
        _ToggleZone(line)
    elseif line.questFocus:IsShown() then
        line.questFocus:Click()
    else
        _ToggleQuest(line)
    end
end

local function _OnToggle()
    local line = selectedLine
    if not line then
        return
    end
    if line.mode == "zone" then
        _ToggleZone(line)
    else
        _ToggleQuest(line)
    end
end

local function _OnUntrack()
    local line = selectedLine
    if not line or line.mode == "zone" then
        return
    end
    if line.Recipe then
        TrackerRecipes.Untrack(line.Recipe.Id)
    elseif line.mode == "achieve" then
        if line.Quest and AchievementTracking.IsTracked(line.Quest.Id) then
            AchievementTracking.Untrack(line.Quest.Id)
            QuestieCombatQueue:Queue(function()
                QuestieTracker:Update()
            end)
        end
    elseif line.Quest then
        QuestieTracker:UntrackQuestId(line.Quest.Id)
    end
end

---Selects the first entry, or activates the navigation when it is not active yet.
function TrackerGamepad.Activate()
    if not _IsAvailable() then
        return
    end
    if InCombatLockdown() then
        UIErrorsFrame:AddMessage(l10n("Can't navigate the Questie tracker in combat."), 1.0, 0.1, 0.1, 1.0)
        return
    end
    if _IsBlizzardUIFocused() then
        return
    end

    local lines = _GetLines()
    if #lines == 0 then
        UIErrorsFrame:AddMessage(l10n("The Questie tracker has nothing to navigate."), 1.0, 0.1, 0.1, 1.0)
        return
    end

    local line
    if active then
        line = lines[1]
    else
        active = true
        elapsedSinceUpdate = 0
        updateFrame:SetScript("OnUpdate", _OnUpdate)
        -- Returns to the last entry, like Blizzard's tracker keeps its last button
        line = _FindLineByKey(lines, selectedKey) or lines[1]
    end
    _Select(line, lines)
end

---@return boolean
function TrackerGamepad.IsActive()
    return active
end

---@return boolean
local function _HasNavigableLines()
    return QuestieTracker.started == true and Questie.db.profile.trackerEnabled and #_GetLines() > 0
end

local function _DisarmFallback()
    if not fallbackArmed or InCombatLockdown() then
        return
    end
    fallbackArmed = false
    ClearOverrideBindings(fallbackOwner)
end

---With no Questie tracker to navigate (disabled, hidden, minimized or empty) the shortcut opens the quest log on the
---world map instead. Opening it from this addon's code would taint the gamepad UI, like handing it the tracker
---would. So the key itself is bound to Blizzard's own TOGGLEQUESTLOG binding, which the client runs untainted, for
---as long as the shortcuts bar is up. The shortcut button's own handler does nothing in this state anyway.
local function _ArmFallback()
    if fallbackArmed or active or InCombatLockdown() or not _IsGamepadUIEnabled() then
        return
    end
    if not (shortcutBar and shortcutBar:IsShown()) then
        return
    end
    if (ObjectiveTrackerFrame and ObjectiveTrackerFrame:IsShown()) or _IsBlizzardUIFocused() or _HasNavigableLines() then
        return
    end

    -- The quest tracker shortcut is action button 2 of the gamepad bar (d-pad up, see Blizzard's Bindings.xml)
    local keys = { GetBindingKey("GAMEPADACTIONBUTTON2") }
    if #keys == 0 then
        keys[1] = KEYS.up
    end
    fallbackArmed = true
    wipe(fallbackKeys)
    for _, key in ipairs(keys) do
        fallbackKeys[key] = true
        SetOverrideBinding(fallbackOwner, true, key, "TOGGLEQUESTLOG")
        -- LB and RB are held and count as SHIFT and CTRL; the exact combination wins over the bare key
        if not key:find("-", 1, true) then
            SetOverrideBinding(fallbackOwner, true, "CTRL-SHIFT-" .. key, "TOGGLEQUESTLOG")
        end
    end
end

---Post-hook of Blizzard's "Access Quest Tracker" shortcut button (LB + RB + Up).
local function _OnShortcutClick(_, _, down)
    if not down then
        return
    end
    -- Blizzard's own handler took the shortcut
    if ObjectiveTrackerFrame and ObjectiveTrackerFrame:IsShown() then
        return
    end
    TrackerGamepad.Activate()
end

---@return boolean hooked
local function _HookShortcutBar()
    if shortcutHooked then
        return true
    end
    local mainBar = GamepadMainActionBarFrame
    local bar = mainBar and mainBar.PageUnit and mainBar.PageUnit.ShortcutsActionBar
    if not (bar and bar.SetUpDpadTop) then
        return false
    end
    shortcutHooked = true
    shortcutBar = bar

    -- The bar is shown exactly while LB + RB are held
    bar:HookScript("OnShow", _ArmFallback)
    bar:HookScript("OnHide", _DisarmFallback)

    local function hookButton()
        -- dpadTopButton follows the action, so it is still the quest tracker button when d-pad and face buttons are swapped
        local button = bar.dpadTopButton
        if button then
            button:HookScript("OnClick", _OnShortcutClick)
        end
    end
    hookButton()
    -- Blizzard sets new click handlers on its buttons when the swap setting changes, which drops the hook
    hooksecurefunc(bar, "SetUpDpadTop", hookButton)
    return true
end

---Blizzard's gamepad UI re-applies its own override bindings whenever its binding stack changes, e.g. when the
---shortcut modifiers are released. If it takes one of our keys while the navigation is active, take it back next
---frame, unless a Blizzard frame got the focus in the meantime. Blizzard always binds with UIParent as owner;
---another owner is another addon's controller navigation (e.g. an open bag window), which keeps the keys.
local function _OnForeignBinding(owner, _, key)
    if fallbackArmed and owner == UIParent and fallbackKeys[key] and not fallbackReassertPending then
        -- Blizzard took the shortcut key back while the bar is still up
        fallbackReassertPending = true
        C_Timer.After(0, function()
            fallbackReassertPending = false
            _DisarmFallback()
            _ArmFallback()
        end)
        return
    end
    if not (active and owner ~= bindingOwner and OUR_KEYS[key]) then
        return
    end
    if owner ~= UIParent then
        TrackerGamepad.Deactivate()
        return
    end
    if not reassertPending then
        reassertPending = true
        C_Timer.After(0, function()
            reassertPending = false
            if active then
                _Refresh()
            end
            if active then
                _ApplyBindings()
            end
        end)
    end
end

-- Runs when the addon loads. Nothing here needs Questie's tracker to exist yet: Questie starts it later, from a
-- coroutine after login, and everything that touches it first checks QuestieTracker.started.
do
    -- Everything is created with UIParent as parent: SmartNavigation hooks CreateFrame and rebuilds the button groups
    -- of the open Blizzard panel a new frame is created in, from the creating addon's (tainted) code.
    bindingOwner = CreateFrame("Frame", "QuestieGamepad_Bindings", UIParent)
    fallbackOwner = CreateFrame("Frame", "QuestieGamepad_FallbackBindings", UIParent)

    highlight = CreateFrame("Frame", "QuestieGamepad_Highlight", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    highlight:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
    highlight:SetBackdropBorderColor(1, 0.82, 0, 0.9)
    highlight:SetFrameStrata("HIGH")
    highlight:Hide()

    footer = CreateFrame("Frame", "QuestieGamepad_Footer", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    footer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    footer:SetBackdropColor(0, 0, 0, 0.6)
    footer:SetFrameStrata("HIGH")
    footer:SetHeight(24)
    footer.text = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footer.text:SetPoint("LEFT", footer, "LEFT", 6, 0)
    footer:Hide()

    local function makeButton(name, onClick)
        local button = CreateFrame("Button", name, UIParent)
        button:RegisterForClicks("AnyDown")
        button:SetScript("OnClick", onClick)
        return button
    end
    navButtons.up = makeButton("QuestieGamepad_Up", function() _Move(-1) end)
    navButtons.down = makeButton("QuestieGamepad_Down", function() _Move(1) end)
    navButtons.select = makeButton("QuestieGamepad_Select", _OnSelect)
    navButtons.toggle = makeButton("QuestieGamepad_Toggle", _OnToggle)
    navButtons.untrack = makeButton("QuestieGamepad_Untrack", _OnUntrack)
    navButtons.back = makeButton("QuestieGamepad_Back", TrackerGamepad.Deactivate)
    noopButton = makeButton("QuestieGamepad_Noop", function() end)

    updateFrame = CreateFrame("Frame", nil, UIParent)

    eventFrame = CreateFrame("Frame", nil, UIParent)
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            -- Last moment the bindings can still be changed; hand the keys back for combat
            TrackerGamepad.Deactivate()
            _DisarmFallback()
        else
            _HookShortcutBar()
        end
    end)

    hooksecurefunc("SetOverrideBinding", _OnForeignBinding)
    hooksecurefunc("SetOverrideBindingClick", _OnForeignBinding)

    -- Every tracker layout ends with RefreshHighlight, which hands the lines to other entries and resets the highlight
    hooksecurefunc(TrackerLinePool, "RefreshHighlight", function()
        if active then
            redrawn = true
            _Refresh()
        end
    end)

    _HookShortcutBar()
end
