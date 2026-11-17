local addonName = ...

-- Keyboard bars use slots 1-180, but the gamepad bar's slot numbers aren't
-- documented, so scan well past that and stop at the first slot the client rejects.
local MAX_SCAN_SLOT = 1000
local GAMEPAD_BARS = { "GamepadMainActionBarFrame" }
local PREFIX = "|cff33ff99AutoRankUp|r: "
local BANK = Enum.SpellBookSpellBank.Player
local SPELL_ITEM = Enum.SpellBookItemType.Spell

local frame = CreateFrame("Frame")
local best        -- [spell name] = { id, index, rank, low, label } for the highest known rank
local known = {}  -- [spellID] = spell name, for every rank in the spellbook
local checkQueued = false
local debug = false

local function Print(msg)
    print(PREFIX .. msg)
end

local function IsLowRank(index)
    if C_SpellBook.IsSpellBookItemLowRank then
        return C_SpellBook.IsSpellBookItemLowRank(index, BANK) and true or false
    end
    return false
end

-- Walks the spellbook and returns the highest rank of every active spell,
-- plus a lookup of every rank's spellID.
local function ScanSpellbook()
    local newBest, newKnown = {}, {}
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
        local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if lineInfo then
            local first = lineInfo.itemIndexOffset + 1
            for index = first, lineInfo.itemIndexOffset + lineInfo.numSpellBookItems do
                local info = C_SpellBook.GetSpellBookItemInfo(index, BANK)
                local id = info and (info.spellID or info.actionID)
                if info and id and info.name and info.itemType == SPELL_ITEM
                    and not info.isPassive and not info.isOffSpec then
                    local label = info.subName or ""
                    local entry = {
                        id = id,
                        index = index,
                        rank = tonumber(label:match("%d+")) or 0,
                        low = IsLowRank(index),
                        label = label,
                    }
                    newKnown[id] = info.name
                    local cur = newBest[info.name]
                    -- the spellbook lists ranks in ascending order, so ties go to the later entry
                    if not cur
                        or (cur.low and not entry.low)
                        or (cur.low == entry.low and entry.rank >= cur.rank) then
                        newBest[info.name] = entry
                    end
                end
            end
        end
    end
    return newBest, newKnown
end

local function PickupRank(entry)
    ClearCursor()
    C_SpellBook.PickupSpellBookItem(entry.index, BANK)
    if GetCursorInfo() ~= "spell" then
        ClearCursor()
        C_Spell.PickupSpell(entry.id)
    end
    return GetCursorInfo() == "spell"
end

local function IsGamepadUI()
    local gamepad = Enum.InputDeviceInterfaceType and Enum.InputDeviceInterfaceType.Gamepad
    if not (gamepad and C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle) then
        return false
    end
    local ok, style = pcall(C_InputInterfaceStyle.GetCurrentStyle)
    return ok and style == gamepad
end

local function ButtonSlot(button)
    local ok, slot = pcall(function()
        if button.CalculateAction then
            return button:CalculateAction()
        end
        return button.action or (button.GetAttribute and button:GetAttribute("action"))
    end)
    return ok and type(slot) == "number" and slot or nil
end

-- Collects the action slots shown by a bar's buttons, however deeply they are nested.
local function CollectBarSlots(frame, slots, depth)
    if depth > 4 or not frame.GetChildren then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        local slot = ButtonSlot(child)
        if slot then
            slots[slot] = true
        end
        CollectBarSlots(child, slots, depth + 1)
    end
end

local function GamepadBarSlots()
    local slots = {}
    for _, name in ipairs(GAMEPAD_BARS) do
        local bar = _G[name]
        if bar then
            CollectBarSlots(bar, slots, 1)
        end
    end
    return slots
end

-- Every action slot that holds a spell, from the keyboard bars and the gamepad bar.
local function SpellSlots()
    local slots, seen = {}, {}
    local function Add(slot)
        if seen[slot] then return true end
        local ok, actionType, id, subType = pcall(GetActionInfo, slot)
        if not ok then return false end
        seen[slot] = true
        if actionType == "spell" and subType ~= "pet" then
            slots[#slots + 1] = { slot = slot, id = id }
        end
        return true
    end
    for slot = 1, MAX_SCAN_SLOT do
        if not Add(slot) then break end
    end
    for slot in pairs(GamepadBarSlots()) do
        Add(slot)
    end
    return slots
end

-- Puts `entry` into every slot in `slots` for which shouldReplace(slotSpellID) is true.
local function ReplaceSlots(slots, entry, shouldReplace)
    local count = 0
    for _, action in ipairs(slots) do
        if shouldReplace(action.id) then
            if PickupRank(entry) then
                PlaceAction(action.slot)
                action.id = entry.id
                count = count + 1
            end
            ClearCursor()
        end
    end
    return count
end

local function Report(name, entry, count)
    if count > 0 then
        local rank = entry.label ~= "" and (" (" .. entry.label .. ")") or ""
        Print(("%s%s placed in %d slot%s."):format(name, rank, count, count == 1 and "" or "s"))
    end
end

-- Compares the spellbook against the last snapshot and upgrades slots that
-- held the previous highest rank. Lower ranks kept on purpose are left alone.
local function Check()
    checkQueued = false
    if InCombatLockdown() then
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    local newBest, newKnown = ScanSpellbook()
    local old = best
    best, known = newBest, newKnown
    if not old then return end

    local slots
    for name, entry in pairs(newBest) do
        local prev = old[name]
        if prev and prev.id ~= entry.id and newKnown[prev.id] then
            if debug then
                Print(("%s: %d -> %d"):format(name, prev.id, entry.id))
            end
            slots = slots or SpellSlots()
            local prevID = prev.id
            Report(name, entry, ReplaceSlots(slots, entry, function(id) return id == prevID end))
        end
    end
end

local function QueueCheck()
    if checkQueued then return end
    checkQueued = true
    C_Timer.After(0.3, Check)
end

-- Manual sweep: every lower rank on the bars becomes the highest known rank.
local function UpgradeAll()
    if InCombatLockdown() then
        Print("Can't change action bars in combat.")
        return
    end
    best, known = ScanSpellbook()
    local slots = SpellSlots()
    local total = 0
    for name, entry in pairs(best) do
        local count = ReplaceSlots(slots, entry, function(id)
            return id ~= entry.id and known[id] == name
        end)
        Report(name, entry, count)
        total = total + count
    end
    if total == 0 then
        Print("Every spell on your bars is already the highest rank.")
    end
end

-- Diagnostic: shows which slots are scanned, so gamepad coverage can be checked in game.
local function ReportSlots()
    local padSlots = {}
    for slot in pairs(GamepadBarSlots()) do
        padSlots[#padSlots + 1] = slot
    end
    table.sort(padSlots)
    Print("Gamepad UI " .. (IsGamepadUI() and "on" or "off") .. ".")
    if #padSlots > 0 then
        Print("Gamepad bar slots: " .. table.concat(padSlots, ", "))
    else
        Print("No gamepad bar buttons found (normal when the gamepad UI is off).")
    end
    local spellSlots, highest = SpellSlots(), 0
    for _, action in ipairs(spellSlots) do
        highest = math.max(highest, action.slot)
    end
    Print(("%d slots hold spells; the highest is slot %d."):format(#spellSlots, highest))
end

frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        self:UnregisterEvent(event)
    end
    QueueCheck()
end)

-- Registering an event the client doesn't know throws, so guard each one.
for _, event in ipairs({ "PLAYER_LOGIN", "SPELLS_CHANGED", "LEARNED_SPELL_IN_SKILL_LINE", "TRAINER_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
end

-- Clicking AutoRankUp in the addon compartment runs the sweep, so gamepad
-- players don't need to type a slash command.
function AutoRankUp_OnAddonCompartmentClick()
    UpgradeAll()
end

SLASH_AUTORANKUP1 = "/autorankup"
SLASH_AUTORANKUP2 = "/aru"
SlashCmdList.AUTORANKUP = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "all" then
        UpgradeAll()
    elseif msg == "slots" then
        ReportSlots()
    elseif msg == "debug" then
        debug = not debug
        Print("Debug " .. (debug and "on" or "off") .. ".")
    else
        Print("Ranks are upgraded automatically when you train them.")
        Print("/aru all - replace every lower rank on your bars with the highest rank")
        Print("/aru slots - show which action slots are scanned, including the gamepad bar")
        Print("/aru debug - print spell IDs when a new rank is detected")
    end
end
