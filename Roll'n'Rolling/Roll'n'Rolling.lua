local addonName = ...
local mainFrame
local iconPool = {}

local ICON_SIZE = 34
local ICON_SPACING = 6
local COLS = 12
local MIN_WIDTH = 460
local MIN_HEIGHT = 240
local MAX_WIDTH = 1100
local MAX_HEIGHT = 900
local unlearnMode = false
local viewMode = "grid" -- "grid", "labels", "list"

-- Session tracking so newly rolled spells/talents appear in their own section
local recentRollCounter = 0
local knownTalentRanks = nil
local knownSpellNames = nil
local talentRecentOrder = {}
local spellRecentOrder = {}
local sessionReady = false

-- Cached items & source metadata so resizing reflows smoothly without rescanning
local cachedTalents = {}
local cachedSpells = {}
local classlessSourceCache = {}

-- Per-character saved locks
RollNRollingDB = RollNRollingDB or {}

local function GetCharacterKey()
    local name = UnitName and UnitName("player") or "Unknown"
    local realm = GetRealmName and GetRealmName() or "Realm"
    return name .. " - " .. realm
end

local function GetCharLockStore()
    RollNRollingDB = RollNRollingDB or {}
    RollNRollingDB.characters = RollNRollingDB.characters or {}
    local key = GetCharacterKey()
    local charData = RollNRollingDB.characters[key]
    if type(charData) ~= "table" then
        charData = { spells = {}, talents = {} }
        RollNRollingDB.characters[key] = charData
    end
    charData.spells = charData.spells or {}
    charData.talents = charData.talents or {}
    return charData
end

local function GetLockKey(name, isTalent)
    if type(name) ~= "string" or name == "" then return nil end
    return name:lower()
end

local function BuildLockedLookup()
    local store = GetCharLockStore()
    local spellLocks = {}
    local talentLocks = {}
    for k, v in pairs(store.spells) do
        if v == true then spellLocks[k] = true end
    end
    for k, v in pairs(store.talents) do
        if v == true then talentLocks[k] = true end
    end
    return spellLocks, talentLocks
end

local function IsLocked(name, isTalent, spellLocks, talentLocks)
    local key = GetLockKey(name, isTalent)
    if not key then return false end
    if spellLocks and talentLocks then
        local bucket = isTalent and talentLocks or spellLocks
        return bucket[key] == true
    end
    local store = GetCharLockStore()
    local bucket = isTalent and store.talents or store.spells
    return bucket[key] == true
end

local function ToggleLock(name, className, isTalent)
    local key = GetLockKey(name, isTalent)
    if not key then return false end
    local store = GetCharLockStore()
    local bucket = isTalent and store.talents or store.spells
    bucket[key] = not bucket[key]
    local nowLocked = bucket[key]
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99Roll'n'Rolling:|r "
        .. (nowLocked and "|cff00ff00Locked|r " or "|cffffaa00Unlocked|r ")
        .. "|cffffd100" .. (name or "Unknown") .. "|r"
        .. (className and className ~= "" and (" (" .. className .. ")") or "")
        .. "."
    )
    return nowLocked
end

local function LockAllCurrent()
    local store = GetCharLockStore()
    local talents = CollectLearnedTalents()
    local spells = CollectLearnedSpells()
    local lockedCount = 0

    for _, t in ipairs(talents) do
        local key = GetLockKey(t.name, true)
        if key then
            store.talents[key] = true
            lockedCount = lockedCount + 1
        end
    end

    for _, s in ipairs(spells) do
        local key = GetLockKey(s.name, false)
        if key then
            store.spells[key] = true
            lockedCount = lockedCount + 1
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99Roll'n'Rolling:|r |cff00ff00Locked all|r (" .. lockedCount .. " items) for this character."
    )
    RefreshRollNRolling()
end

local function UnlockAllCurrent()
    local store = GetCharLockStore()
    local unlockedCount = 0

    for _, v in pairs(store.talents) do
        if v == true then
            unlockedCount = unlockedCount + 1
        end
    end
    for _, v in pairs(store.spells) do
        if v == true then
            unlockedCount = unlockedCount + 1
        end
    end

    store.talents = {}
    store.spells = {}

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff33ff99Roll'n'Rolling:|r |cffffaa00Unlocked all|r (" .. unlockedCount .. " items) for this character."
    )
    RefreshRollNRolling()
end

local VALID_CLASSES = {}
do
    if FillLocalizedClassList then
        local male, female = {}, {}
        FillLocalizedClassList(male, false)
        FillLocalizedClassList(female, true)
        for _, c in pairs(male) do
            if type(c) == "string" then VALID_CLASSES[c:lower()] = c end
        end
        for _, c in pairs(female) do
            if type(c) == "string" then VALID_CLASSES[c:lower()] = c end
        end
    end
    for _, c in ipairs({
        "Warrior", "Paladin", "Hunter", "Rogue", "Priest",
        "Death Knight", "Shaman", "Mage", "Warlock", "Druid", "Monk",
    }) do
        local key = c:lower()
        VALID_CLASSES[key] = VALID_CLASSES[key] or c
    end
end

-- Excluded basic attack / shoot / throw spell IDs (3.3.5a)
local EXCLUDED_SPELL_IDS = {
    [6603] = true, -- Auto Attack
    [5019] = true, -- Shoot (Wand)
    [3018] = true, -- Shoot (Bow/Gun/Crossbow)
    [2764] = true, -- Throw
}

-- Excluded basic attack / shoot / throw names (fallback if spellLink lacks ID)
local EXCLUDED_SPELL_NAMES = {
    ["auto attack"] = true,
    ["shoot"]       = true,
    ["throw"]       = true,
}
for _, globalKey in ipairs({ "ATTACK", "SHOOT", "THROW" }) do
    local localized = _G[globalKey]
    if type(localized) == "string" and localized ~= "" then
        EXCLUDED_SPELL_NAMES[localized:lower()] = true
    end
end

-- Profession & non-combat utility skill names / spell names to exclude
local PROFESSION_KEYWORDS = {
    ["alchemy"] = true,
    ["blacksmithing"] = true,
    ["enchanting"] = true,
    ["engineering"] = true,
    ["herbalism"] = true,
    ["inscription"] = true,
    ["jewelcrafting"] = true,
    ["leatherworking"] = true,
    ["mining"] = true,
    ["skinning"] = true,
    ["tailoring"] = true,
    ["cooking"] = true,
    ["first aid"] = true,
    ["fishing"] = true,
    ["riding"] = true,
    ["smelting"] = true,
    ["disenchant"] = true,
    ["prospecting"] = true,
    ["milling"] = true,
    ["find herbs"] = true,
    ["find minerals"] = true,
    ["find treasure"] = true,
    ["find fish"] = true,
    ["basic campfire"] = true,
    ["runeforging"] = true,
}

local function BuildPlayerProfessionSet()
    local profs = {}
    for k, v in pairs(PROFESSION_KEYWORDS) do
        profs[k] = v
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local skillName, isHeader = GetSkillLineInfo(i)
            if not isHeader and type(skillName) == "string" and skillName ~= "" then
                local lower = skillName:lower()
                if PROFESSION_KEYWORDS[lower] then
                    profs[lower] = true
                end
            end
        end
    end
    return profs
end

local function IsExcludedSpell(spellName, spellRank, spellId, tabName, profSet)
    if spellId and EXCLUDED_SPELL_IDS[spellId] then
        return true
    end

    local nameLower = type(spellName) == "string" and spellName:lower() or ""
    if nameLower == "" or EXCLUDED_SPELL_NAMES[nameLower] then
        return true
    end

    if type(spellRank) == "string" and spellRank:lower():find("racial", 1, true) then
        return true
    end

    local tabLower = type(tabName) == "string" and tabName:lower() or ""
    if tabLower ~= "" and profSet[tabLower] then
        return true
    end
    if profSet[nameLower] then
        return true
    end

    return false
end

local function IsTexturePath(val)
    if type(val) ~= "string" then return false end
    local lower = val:lower()
    return lower:find("interface\\", 1, true)
        or lower:find("interface/", 1, true)
        or lower:find("%.blp$")
end

local function CleanText(val)
    if type(val) ~= "string" then return nil end
    local cleaned = val:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^%s*(.-)%s*$")
    return (cleaned ~= "") and cleaned or nil
end

local function MatchClassName(text)
    local cleaned = CleanText(text)
    if not cleaned or IsTexturePath(cleaned) then return nil end
    local lower = cleaned:lower()
    if VALID_CLASSES[lower] then return VALID_CLASSES[lower] end
    for key, properName in pairs(VALID_CLASSES) do
        if lower:find(key, 1, true) then return properName end
    end
    return nil
end

local function ParseTreeAndClassFromStrings(a, b)
    local sa, sb = CleanText(a), CleanText(b)
    if sa and sa:find("%s*-%s*") then
        local left, right = sa:match("^(.-)%s*%-%s*(.+)$")
        left, right = CleanText(left), CleanText(right)
        local cls = MatchClassName(right) or MatchClassName(left)
        if cls then
            local tree = (cls == right) and left or right
            if tree and tree:lower() == cls:lower() then tree = nil end
            return tree, cls
        end
    end
    if sb and sb:find("%s*-%s*") then
        local left, right = sb:match("^(.-)%s*%-%s*(.+)$")
        left, right = CleanText(left), CleanText(right)
        local cls = MatchClassName(right) or MatchClassName(left)
        if cls then
            local tree = (cls == right) and left or right
            if tree and tree:lower() == cls:lower() then tree = nil end
            return tree, cls
        end
    end

    local clsA = MatchClassName(sa)
    local clsB = MatchClassName(sb)
    if clsA then
        return (sb and not IsTexturePath(sb) and sb:lower() ~= clsA:lower()) and sb or nil, clsA
    end
    if clsB then
        return (sa and not IsTexturePath(sa) and sa:lower() ~= clsB:lower()) and sa or nil, clsB
    end

    return nil, nil
end

local function GetSavedSourceCache()
    RollNRollingDB = RollNRollingDB or {}
    RollNRollingDB.sourceCache = RollNRollingDB.sourceCache or {}
    return RollNRollingDB.sourceCache
end

local function RecordClasslessEntry(entryName, treeName, className)
    local cleanName = CleanText(entryName)
    if not cleanName or IsTexturePath(cleanName) then return end

    local parsedTree, parsedClass = ParseTreeAndClassFromStrings(treeName, className)
    local finalClass = parsedClass or MatchClassName(className) or MatchClassName(treeName)
    local finalTree = parsedTree
    if not finalTree and treeName and not IsTexturePath(treeName) then
        local tClean = CleanText(treeName)
        if tClean and (not finalClass or tClean:lower() ~= finalClass:lower()) then
            finalTree = tClean
        end
    end

    if finalClass or finalTree then
        local key = cleanName:lower()
        local existing = classlessSourceCache[key] or {}
        existing.className = finalClass or existing.className
        existing.treeName = finalTree or existing.treeName
        classlessSourceCache[key] = existing

        local saved = GetSavedSourceCache()
        saved[key] = {
            className = existing.className,
            treeName = existing.treeName,
        }
    end
end

local function ScrapeFontStringsFromRow(frame, entryName)
    if not frame then return nil, nil end
    local texts = {}
    local entryLower = entryName and entryName:lower() or nil

    local function collect(f, depth)
        if not f or depth > 3 then return end
        if f.GetRegions then
            for _, region in ipairs({ f:GetRegions() }) do
                if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
                    local txt = CleanText(region:GetText())
                    if txt and not IsTexturePath(txt) and txt:lower() ~= entryLower then
                        table.insert(texts, txt)
                    end
                end
            end
        end
        if f.GetChildren then
            for _, child in ipairs({ f:GetChildren() }) do
                collect(child, depth + 1)
            end
        end
    end

    collect(frame, 0)

    for _, txt in ipairs(texts) do
        local tree, cls = ParseTreeAndClassFromStrings(txt, nil)
        if tree or cls then
            return tree, cls
        end
    end
    return nil, nil
end

local function RefreshClasslessSourceCache()
    if not ClasslessFrame_Freepick then return end

    local function scan(frame, depth)
        if not frame or depth > 8 then return end
        local data = (type(frame.talentData) == "table" and frame.talentData)
            or (type(frame.spellData) == "table" and frame.spellData)
            or nil

        if type(data) == "table" then
            local entryName = data.name or data.searchName
            local rawSub = data.subText or data.source or data.className or data.class or data.tabName or data.treeName
            local rawTree = data.treeName or data.specName or data.tabName
            local tree, cls = ParseTreeAndClassFromStrings(rawTree, rawSub)
            if not tree and not cls then
                tree, cls = ScrapeFontStringsFromRow(frame, entryName)
            end
            RecordClasslessEntry(entryName, tree or rawTree, cls or rawSub)
            if type(data.searchName) == "string" and data.searchName ~= entryName then
                RecordClasslessEntry(data.searchName, tree or rawTree, cls or rawSub)
            end
        end

        if frame.GetChildren then
            for _, child in ipairs({ frame:GetChildren() }) do
                scan(child, depth + 1)
            end
        end
    end

    scan(ClasslessFrame_Freepick, 0)
end

local function FormatSourceLabel(treeName, className, fallbackTabName)
    local cleanClass = MatchClassName(className) or MatchClassName(fallbackTabName)
    local cleanTree = CleanText(treeName)
    if cleanTree and IsTexturePath(cleanTree) then cleanTree = nil end
    if cleanTree and cleanClass and cleanTree:lower() == cleanClass:lower() then
        cleanTree = nil
    end

    if cleanTree and cleanClass then
        return string.format("%s - %s", cleanTree, cleanClass)
    elseif cleanClass then
        return cleanClass
    elseif cleanTree then
        return cleanTree
    elseif fallbackTabName and CleanText(fallbackTabName) and not IsTexturePath(fallbackTabName)
        and CleanText(fallbackTabName):lower() ~= "general" then
        return CleanText(fallbackTabName)
    end
    return "Classless"
end

local function ResolveSourceFromNameAndTab(name, tabName, skipScan)
    if not skipScan then
        RefreshClasslessSourceCache()
    end
    local key = name and name:lower()
    local cached = key and (classlessSourceCache[key] or GetSavedSourceCache()[key])
    if cached then
        return FormatSourceLabel(cached.treeName, cached.className, tabName)
    end
    return FormatSourceLabel(nil, nil, tabName)
end

local function FormatNameWithClass(name, className)
    local cleanClass = (className and className ~= "" and not IsTexturePath(className)) and className or nil
    if cleanClass then
        return string.format("%s - %s", name or "Unknown", cleanClass)
    end
    return name or "Unknown"
end

local function GetRowData(frame, expectTalent)
    if not frame then return nil end
    if expectTalent == true then
        return type(frame.talentData) == "table" and frame.talentData or nil
    elseif expectTalent == false then
        return type(frame.spellData) == "table" and frame.spellData or nil
    end
    if type(frame.spellData) == "table" then return frame.spellData end
    if type(frame.talentData) == "table" then return frame.talentData end
    return nil
end

local function RowMatchesEntry(data, entry)
    if type(data) ~= "table" or not entry or not entry.name then return false end
    local targetLower = entry.name:lower()

    if type(data.name) == "string" and data.name:lower() == targetLower then
        return true
    end
    if type(data.searchName) == "string" and data.searchName:lower() == targetLower then
        return true
    end

    return false
end

local function ClickTabFrame(tabFrame)
    if not tabFrame then return false end
    local script = tabFrame:GetScript("OnClick") or tabFrame:GetScript("OnMouseUp")
    if type(script) == "function" then
        pcall(script, tabFrame, "LeftButton")
        return true
    end
    if tabFrame.Click then
        pcall(tabFrame.Click, tabFrame)
        return true
    end
    return false
end

local function DetectActiveCustomTab()
    local t1 = _G["ClasslessFrame_FreepickLearnedListCustomTab1"]
    local t2 = _G["ClasslessFrame_FreepickLearnedListCustomTab2"]
    if t2 and t2.IsSelected and t2:IsSelected() then return t2 end
    if t1 and t1.IsSelected and t1:IsSelected() then return t1 end
    return nil
end

local function EnsureFreepickTabForEntry(entry)
    local spellsTab = _G["ClasslessFrame_FreepickLearnedListCustomTab1"]
    local talentsTab = _G["ClasslessFrame_FreepickLearnedListCustomTab2"]
    local prevTab = DetectActiveCustomTab()
    local targetTab = entry.isTalent and talentsTab or spellsTab

    if targetTab and targetTab ~= prevTab then
        ClickTabFrame(targetTab)
    end

    return function()
        if prevTab and prevTab ~= targetTab then
            ClickTabFrame(prevTab)
        end
    end
end

local function ScanVisibleRowForEntry(entry)
    if not ClasslessFrame_Freepick or not entry then return nil end
    local found = nil

    local function scan(frame)
        if found or not frame or not frame.GetChildren then return end
        for _, child in ipairs({ frame:GetChildren() }) do
            if child:IsShown() then
                local data = GetRowData(child, entry.isTalent)
                if RowMatchesEntry(data, entry) then
                    found = child
                    return
                end
            end
            scan(child)
            if found then return end
        end
    end

    scan(ClasslessFrame_Freepick)
    return found
end

local function CollectFreepickSliders()
    local sliders = {}
    local function scan(frame)
        if not frame or not frame.GetChildren then return end
        for _, child in ipairs({ frame:GetChildren() }) do
            if child.GetObjectType and child:GetObjectType() == "Slider"
                and child.GetMinMaxValues and child.SetValue then
                table.insert(sliders, child)
            end
            scan(child)
        end
    end
    if ClasslessFrame_Freepick then
        scan(ClasslessFrame_Freepick)
    end
    return sliders
end

local function FindRowWithSliderSweep(entry)
    local match = ScanVisibleRowForEntry(entry)
    if match then return match end

    for _, slider in ipairs(CollectFreepickSliders()) do
        local minVal, maxVal = slider:GetMinMaxValues()
        local origVal = slider:GetValue()
        if maxVal and maxVal > (minVal or 0) then
            local span = maxVal - (minVal or 0)
            for s = 0, 30 do
                slider:SetValue((minVal or 0) + (span * (s / 30)))
                match = ScanVisibleRowForEntry(entry)
                if match then
                    return match, function()
                        slider:SetValue(origVal)
                    end
                end
            end
            slider:SetValue(origVal)
        end
    end

    return nil, nil
end

local function FindClickableTarget(btn)
    local curr = btn
    for _ = 1, 5 do
        if not curr then break end
        if curr:GetScript("OnMouseUp") or curr:GetScript("OnClick") then
            return curr
        end
        curr = curr:GetParent()
    end
    return btn
end

local function CleanDropdownText(txt)
    if type(txt) ~= "string" then return nil end
    txt = txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^%s*(.-)%s*$")
    return (txt ~= "") and txt or nil
end

local function GetDropdownButtonText(btn)
    if not btn then return nil end
    if btn.GetText then
        local txt = CleanDropdownText(btn:GetText())
        if txt then return txt end
    end
    local name = btn:GetName()
    if name then
        for _, suffix in ipairs({ "NormalText", "Text", "Label" }) do
            local fs = _G[name .. suffix]
            if fs and fs.GetText then
                local txt = CleanDropdownText(fs:GetText())
                if txt then return txt end
            end
        end
    end
    return nil
end

local function InvokeDropdownUnlearn()
    if not DropDownList1 or not DropDownList1:IsShown() then
        return false
    end

    for i = 1, (UIDROPDOWNMENU_MAXBUTTONS or 10) do
        local ddBtn = _G["DropDownList1Button" .. i]
        if ddBtn and ddBtn:IsShown() and type(ddBtn.func) == "function" then
            local label = GetDropdownButtonText(ddBtn)
            if ddBtn.value == "Unlearn" or (label and label:lower() == "unlearn") then
                ddBtn.func(ddBtn, ddBtn.arg1, ddBtn.arg2)
                if CloseDropDownMenus then CloseDropDownMenus() end
                return true
            end
        end
    end
    return false
end

local function TriggerNativeUnlearn(entry)
    if not entry then return end

    if IsLocked(entry.name, entry.isTalent) then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff33ff99Roll'n'Rolling:|r |cffffd100"
            .. FormatNameWithClass(entry.name, entry.className)
            .. "|r is |cff00ff00locked|r. Unlock it first if you want to unlearn it."
        )
        return
    end

    if not ClasslessFrame_Freepick or not ClasslessFrame_Freepick:IsShown() then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff33ff99Roll'n'Rolling:|r Open Classless first to unlearn |cffffd100"
            .. FormatNameWithClass(entry.name, entry.className)
            .. "|r."
        )
        return
    end

    local matchedBtn, restoreSlider = FindRowWithSliderSweep(entry)
    local restoreTab = nil

    if not matchedBtn then
        restoreTab = EnsureFreepickTabForEntry(entry)
        matchedBtn, restoreSlider = FindRowWithSliderSweep(entry)
    end

    local target = FindClickableTarget(matchedBtn)
    local script = target and (target:GetScript("OnMouseUp") or target:GetScript("OnClick"))
    local currentData = GetRowData(matchedBtn, entry.isTalent)
    local triggered = false

    if matchedBtn and RowMatchesEntry(currentData, entry) and target and script then
        local origMouseIsOver = _G.MouseIsOver
        local origGetBtn = _G.GetMouseButtonClicked
        _G.MouseIsOver = function() return true end
        _G.GetMouseButtonClicked = function() return "RightButton" end

        local ok = pcall(script, target, "RightButton")

        _G.MouseIsOver = origMouseIsOver
        _G.GetMouseButtonClicked = origGetBtn

        if ok and InvokeDropdownUnlearn() then
            triggered = true
        end
    end

    if restoreSlider then restoreSlider() end
    if restoreTab then restoreTab() end

    if not triggered then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff33ff99Roll'n'Rolling:|r Could not unlearn |cffffd100"
            .. FormatNameWithClass(entry.name, entry.className)
            .. "|r."
        )
    end
end

local function GetIconButton(parent, index)
    local btn = iconPool[index]
    if not btn then
        btn = CreateFrame("Button", "RollNRollingIcon" .. index, parent)
        btn:SetSize(ICON_SIZE, ICON_SIZE)

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetSize(ICON_SIZE, ICON_SIZE)
        tex:SetPoint("LEFT", btn, "LEFT", 0, 0)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn.icon = tex

        local border = btn:CreateTexture(nil, "BACKGROUND")
        border:SetTexture("Interface\\Buttons\\WHITE8X8")
        border:SetPoint("TOPLEFT", tex, "TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 1, -1)
        border:SetVertexColor(0.25, 0.25, 0.30, 1)
        btn.border = border

        local rowBg = btn:CreateTexture(nil, "BACKGROUND")
        rowBg:SetTexture("Interface\\Buttons\\WHITE8X8")
        rowBg:SetAllPoints(btn)
        rowBg:SetVertexColor(0.12, 0.12, 0.16, 0.75)
        rowBg:Hide()
        btn.rowBg = rowBg

        local lockBadge = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        lockBadge:SetPoint("TOPLEFT", tex, "TOPLEFT", 2, -2)
        lockBadge:SetText("|cff00ff00L|r")
        lockBadge:Hide()
        btn.lockBadge = lockBadge

        local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        count:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", -2, 2)
        btn.count = count

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
        label:SetWidth(ICON_SIZE + 28)
        label:SetWordWrap(false)
        btn.label = label

        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnDragStart", function(self)
            if unlearnMode or IsShiftKeyDown() then return end
            if self.spellBookId then
                PickupSpell(self.spellBookId, BOOKTYPE_SPELL)
            elseif self.spellName then
                PickupSpell(self.spellName)
            end
        end)

        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:SetScript("OnClick", function(self, mouseButton)
            if IsShiftKeyDown() or (mouseButton == "RightButton" and not unlearnMode) then
                ToggleLock(self.spellName, self.className, self.isTalent)
                ReflowRollNRolling()
                return
            end

            if not unlearnMode then return end
            TriggerNativeUnlearn({
                name = self.spellName,
                className = self.className,
                spellId = self.spellId,
                ids = self.ids,
                talentTab = self.talentTab,
                talentIndex = self.talentIndex,
                isTalent = self.isTalent,
            })
        end)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.spellBookId then
                GameTooltip:SetSpell(self.spellBookId, BOOKTYPE_SPELL)
            elseif self.talentTab and self.talentIndex then
                GameTooltip:SetTalent(self.talentTab, self.talentIndex)
            end
            local resolvedSource = ResolveSourceFromNameAndTab(self.spellName, self.className, false)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff66ccffSource:|r " .. FormatNameWithClass(self.spellName, resolvedSource))
            if self.isLocked then
                GameTooltip:AddLine("|cff00ff00Locked (Saved for this character)|r")
            end
            if self.isRecent then
                GameTooltip:AddLine("|cff33ff99Recently Rolled|r")
            end
            if unlearnMode then
                if self.isLocked then
                    GameTooltip:AddLine("|cff00ff00Locked: Unlock before unlearning|r")
                else
                    GameTooltip:AddLine("|cffff4444Unlearn Mode Active: Click to unlearn|r")
                end
            else
                GameTooltip:AddLine("|cffaaaaaaShift-Click or Right-Click to Lock/Unlock|r")
            end
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        iconPool[index] = btn
    end

    btn:SetParent(parent)
    btn:SetSize(ICON_SIZE, ICON_SIZE)
    btn.rowBg:Hide()
    btn.lockBadge:Hide()
    btn.spellBookId = nil
    btn.spellName = nil
    btn.className = nil
    btn.spellId = nil
    btn.ids = nil
    btn.talentTab = nil
    btn.talentIndex = nil
    btn.isTalent = false
    btn.isRecent = false
    btn.isLocked = false
    btn.count:SetText("")
    btn.label:ClearAllPoints()
    btn.label:SetText("")
    btn.label:Hide()
    btn:Show()
    return btn
end

local function SortSectionWithLockedAtEnd(list, prioritizeRecent, spellLocks, talentLocks)
    table.sort(list, function(a, b)
        local aLocked = IsLocked(a.name, a.isTalent, spellLocks, talentLocks)
        local bLocked = IsLocked(b.name, b.isTalent, spellLocks, talentLocks)
        if aLocked ~= bLocked then
            return not aLocked
        end
        if prioritizeRecent and (a.recentOrder or 0) ~= (b.recentOrder or 0) then
            return (a.recentOrder or 0) > (b.recentOrder or 0)
        end
        return a.baseOrder < b.baseOrder
    end)
end

function CollectLearnedTalents()
    local results = {}
    if not GetNumTalentTabs or not GetNumTalents or not GetTalentInfo then
        cachedTalents = results
        return results
    end

    local isBaseline = (knownTalentRanks == nil) or (not sessionReady)
    if knownTalentRanks == nil then knownTalentRanks = {} end

    local currentRanks = {}
    local seq = 0

    for tab = 1, GetNumTalentTabs() do
        local tabName = GetTalentTabInfo and select(2, GetTalentTabInfo(tab))
        for idx = 1, GetNumTalents(tab) do
            local name, iconTexture, _, _, currentRank, maxRank = GetTalentInfo(tab, idx)
            if name and currentRank and currentRank > 0 then
                seq = seq + 1
                local key = name:lower()
                currentRanks[key] = currentRank

                if not isBaseline then
                    local prevRank = knownTalentRanks[key] or 0
                    if currentRank > prevRank then
                        recentRollCounter = recentRollCounter + 1
                        talentRecentOrder[key] = recentRollCounter
                    elseif currentRank < prevRank then
                        talentRecentOrder[key] = nil
                    end
                end

                table.insert(results, {
                    name = name,
                    className = ResolveSourceFromNameAndTab(name, tabName, true),
                    icon = iconTexture,
                    rankText = currentRank .. "/" .. (maxRank or currentRank),
                    talentTab = tab,
                    talentIndex = idx,
                    isTalent = true,
                    recentOrder = talentRecentOrder[key] or 0,
                    baseOrder = seq,
                })
            end
        end
    end

    if not isBaseline then
        for oldKey in pairs(knownTalentRanks) do
            if not currentRanks[oldKey] then
                talentRecentOrder[oldKey] = nil
            end
        end
    end

    knownTalentRanks = currentRanks
    cachedTalents = results
    return results
end

function CollectLearnedSpells()
    local byName = {}
    local ordered = {}

    if not GetNumSpellTabs or not GetSpellTabInfo then
        cachedSpells = ordered
        return ordered
    end

    local isBaseline = (knownSpellNames == nil) or (not sessionReady)
    if knownSpellNames == nil then knownSpellNames = {} end

    local profSet = BuildPlayerProfessionSet()
    local currentSpells = {}
    local seq = 0

    for tab = 1, GetNumSpellTabs() do
        local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
        for i = offset + 1, offset + numSpells do
            local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
            local icon = GetSpellTexture(i, BOOKTYPE_SPELL)
            local spellLink = GetSpellLink and GetSpellLink(i, BOOKTYPE_SPELL)
            local spellId = spellLink and tonumber(spellLink:match("spell:(%d+)"))

            if spellName and icon
                and not IsPassiveSpell(i, BOOKTYPE_SPELL)
                and not IsExcludedSpell(spellName, spellRank, spellId, tabName, profSet) then
                local key = spellName:lower()
                currentSpells[key] = true

                if not isBaseline and not knownSpellNames[key] then
                    recentRollCounter = recentRollCounter + 1
                    spellRecentOrder[key] = recentRollCounter
                end

                local resolvedClass = ResolveSourceFromNameAndTab(spellName, tabName, true)

                if not byName[spellName] then
                    seq = seq + 1
                    byName[spellName] = {
                        name = spellName,
                        className = resolvedClass,
                        rank = spellRank,
                        icon = icon,
                        spellBookId = i,
                        spellId = spellId,
                        ids = spellId and { [spellId] = true } or {},
                        isTalent = false,
                        recentOrder = spellRecentOrder[key] or 0,
                        baseOrder = seq,
                    }
                    table.insert(ordered, byName[spellName])
                else
                    local entry = byName[spellName]
                    entry.spellBookId = i
                    entry.spellId = spellId or entry.spellId
                    entry.rank = spellRank
                    entry.recentOrder = spellRecentOrder[key] or entry.recentOrder
                    if spellId then entry.ids[spellId] = true end
                    if resolvedClass ~= "Classless" then
                        entry.className = resolvedClass
                    end
                end
            end
        end
    end

    if not isBaseline then
        for oldKey in pairs(knownSpellNames) do
            if not currentSpells[oldKey] then
                spellRecentOrder[oldKey] = nil
            end
        end
    end

    knownSpellNames = currentSpells
    cachedSpells = ordered
    return ordered
end

local function ApplyBorderColor(btn, isRecent, isLocked, defaultR, defaultG, defaultB)
    if unlearnMode and not isLocked then
        btn.border:SetVertexColor(0.90, 0.25, 0.25, 1)
    elseif isLocked then
        btn.border:SetVertexColor(0.20, 0.85, 0.35, 1)
    elseif isRecent then
        btn.border:SetVertexColor(0.35, 0.90, 0.95, 1)
    else
        btn.border:SetVertexColor(defaultR, defaultG, defaultB, 1)
    end
end

local function ConfigureItemView(btn, item, rowWidth)
    local displayName = FormatNameWithClass(item.name, item.className)
    if item.isLocked then
        displayName = "|cff00ff00[Locked]|r " .. displayName
    end

    if viewMode == "list" then
        btn:SetSize(rowWidth, ICON_SIZE)
        btn.rowBg:Show()
        btn.label:SetPoint("LEFT", btn.icon, "RIGHT", 10, 0)
        btn.label:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
        btn.label:SetJustifyH("LEFT")
        btn.label:SetWordWrap(false)
        btn.label:SetText(displayName)
        btn.label:Show()
    elseif viewMode == "labels" then
        btn:SetSize(ICON_SIZE, ICON_SIZE)
        btn.label:SetPoint("TOP", btn.icon, "BOTTOM", 0, -2)
        btn.label:SetWidth(ICON_SIZE + 28)
        btn.label:SetJustifyH("CENTER")
        btn.label:SetWordWrap(false)
        btn.label:SetText(FormatNameWithClass(item.name, item.className))
        btn.label:Show()
    else
        btn:SetSize(ICON_SIZE, ICON_SIZE)
    end
end

local function GetViewButtonText()
    if viewMode == "labels" then
        return "|cff66ccffView: Labels|r"
    elseif viewMode == "list" then
        return "|cff66ccffView: List|r"
    end
    return "View: Grid"
end

local function PopulateIconSection(content, items, cols, hSpacing, vSpacing, startY, poolIdx, defaultR, defaultG, defaultB, availWidth, spellLocks, talentLocks)
    local y = startY
    for i, item in ipairs(items) do
        poolIdx = poolIdx + 1
        local btn = GetIconButton(content, poolIdx)
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + col * (ICON_SIZE + hSpacing), y - row * (ICON_SIZE + vSpacing))
        btn.icon:SetTexture(item.icon)

        local locked = IsLocked(item.name, item.isTalent, spellLocks, talentLocks)
        btn.isLocked = locked
        if locked then
            btn.lockBadge:Show()
        end

        ApplyBorderColor(btn, item.recentOrder > 0, locked, defaultR, defaultG, defaultB)
        if item.rankText then
            btn.count:SetText(item.rankText)
        end
        btn.spellBookId = item.spellBookId
        btn.spellName = item.name
        btn.className = item.className
        btn.spellId = item.spellId
        btn.ids = item.ids
        btn.talentTab = item.talentTab
        btn.talentIndex = item.talentIndex
        btn.isTalent = item.isTalent
        btn.isRecent = (item.recentOrder > 0)
        ConfigureItemView(btn, item, availWidth)
    end
    local rows = math.max(1, math.ceil(#items / cols))
    return poolIdx, y - rows * (ICON_SIZE + vSpacing)
end

-- Fast layout reflow from already-collected data (used during window resizing & lock toggles)
function ReflowRollNRolling()
    if not mainFrame then return end

    for _, btn in ipairs(iconPool) do
        btn:Hide()
    end

    local spellLocks, talentLocks = BuildLockedLookup()
    local content = mainFrame.content

    local recentItems = {}
    local learnedTalents = {}
    local learnedSpells = {}

    for _, t in ipairs(cachedTalents) do
        if (t.recentOrder or 0) > 0 then
            table.insert(recentItems, t)
        else
            table.insert(learnedTalents, t)
        end
    end

    for _, s in ipairs(cachedSpells) do
        if (s.recentOrder or 0) > 0 then
            table.insert(recentItems, s)
        else
            table.insert(learnedSpells, s)
        end
    end

    SortSectionWithLockedAtEnd(recentItems, true, spellLocks, talentLocks)
    SortSectionWithLockedAtEnd(learnedTalents, false, spellLocks, talentLocks)
    SortSectionWithLockedAtEnd(learnedSpells, false, spellLocks, talentLocks)

    local isList = (viewMode == "list")
    local isLabels = (viewMode == "labels")

    local vSpacing = isLabels and (ICON_SPACING + 16) or ICON_SPACING
    local hSpacing = isLabels and (ICON_SPACING + 26) or ICON_SPACING
    local availWidth = math.max(140, (mainFrame.scroll and mainFrame.scroll:GetWidth() or (mainFrame:GetWidth() - 34)) - 24)
    local cols = isList and 1 or math.max(3, math.floor((availWidth + hSpacing) / (ICON_SIZE + hSpacing)))
    content:SetWidth(availWidth)

    local poolIdx = 0
    local yOffset = -6

    if #recentItems > 0 then
        mainFrame.recentHeader:ClearAllPoints()
        mainFrame.recentHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
        mainFrame.recentHeader:SetText(string.format("Recently Rolled (%d)", #recentItems))
        mainFrame.recentHeader:Show()
        yOffset = yOffset - 22

        poolIdx, yOffset = PopulateIconSection(
            content, recentItems, cols, hSpacing, vSpacing, yOffset, poolIdx,
            0.35, 0.90, 0.95, availWidth, spellLocks, talentLocks
        )
        yOffset = yOffset - 14
    else
        mainFrame.recentHeader:Hide()
    end

    mainFrame.talentHeader:ClearAllPoints()
    mainFrame.talentHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
    mainFrame.talentHeader:SetText(string.format("Learned Talents (%d)", #learnedTalents))
    yOffset = yOffset - 22

    if #learnedTalents == 0 then
        mainFrame.noTalentsText:Show()
        mainFrame.noTalentsText:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
        yOffset = yOffset - 26
    else
        mainFrame.noTalentsText:Hide()
        poolIdx, yOffset = PopulateIconSection(
            content, learnedTalents, cols, hSpacing, vSpacing, yOffset, poolIdx,
            0.85, 0.65, 0.15, availWidth, spellLocks, talentLocks
        )
        yOffset = yOffset - 14
    end

    mainFrame.spellHeader:ClearAllPoints()
    mainFrame.spellHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
    mainFrame.spellHeader:SetText(string.format("Learned Active Spells (%d)", #learnedSpells))
    yOffset = yOffset - 22

    poolIdx, yOffset = PopulateIconSection(
        content, learnedSpells, cols, hSpacing, vSpacing, yOffset, poolIdx,
        0.25, 0.75, 0.40, availWidth, spellLocks, talentLocks
    )

    content:SetHeight(math.abs(yOffset) + 28)
end

function RefreshRollNRolling()
    if not mainFrame then return end
    RefreshClasslessSourceCache()
    CollectLearnedTalents()
    CollectLearnedSpells()
    ReflowRollNRolling()
end

local resizeDebounceFrame = CreateFrame("Frame")
resizeDebounceFrame:Hide()
resizeDebounceFrame.elapsed = 0
resizeDebounceFrame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed >= 0.05 then
        self.elapsed = 0
        self:Hide()
        if mainFrame and mainFrame:IsShown() then
            ReflowRollNRolling()
        end
    end
end)

local function ScheduleResizeReflow()
    if mainFrame and mainFrame:IsShown() then
        resizeDebounceFrame.elapsed = 0
        resizeDebounceFrame:Show()
    end
end

local function CreateMainWindow()
    if mainFrame then return mainFrame end

    local width = math.max(MIN_WIDTH, 12 + COLS * (ICON_SIZE + ICON_SPACING) + 32)
    local f = CreateFrame("Frame", "RollNRollingFrame", UIParent)
    f:SetSize(width, 460)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetMinResize then
        f:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
        f:SetMaxResize(MAX_WIDTH, MAX_HEIGHT)
    end
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ReflowRollNRolling()
    end)
    f:Hide()

    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
    f:SetBackdropBorderColor(0.28, 0.28, 0.34, 1)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refresh:SetSize(56, 20)
    refresh:SetPoint("RIGHT", close, "LEFT", -3, 0)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", RefreshRollNRolling)

    local viewBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    viewBtn:SetSize(88, 20)
    viewBtn:SetPoint("RIGHT", refresh, "LEFT", -3, 0)
    viewBtn:SetText(GetViewButtonText())
    viewBtn:SetScript("OnClick", function(self)
        if viewMode == "grid" then
            viewMode = "labels"
        elseif viewMode == "labels" then
            viewMode = "list"
        else
            viewMode = "grid"
        end
        self:SetText(GetViewButtonText())
        ReflowRollNRolling()
    end)

    local modeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    modeBtn:SetSize(84, 20)
    modeBtn:SetPoint("RIGHT", viewBtn, "LEFT", -3, 0)
    modeBtn:SetText("Unlearn: OFF")
    modeBtn:SetScript("OnClick", function(self)
        unlearnMode = not unlearnMode
        self:SetText(unlearnMode and "|cffff4444Unlearn: ON|r" or "Unlearn: OFF")
        f:SetBackdropBorderColor(unlearnMode and 0.85 or 0.28, unlearnMode and 0.20 or 0.28, unlearnMode and 0.20 or 0.34, 1)
        ReflowRollNRolling()
    end)

    local unlockAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    unlockAllBtn:SetSize(72, 20)
    unlockAllBtn:SetPoint("RIGHT", modeBtn, "LEFT", -3, 0)
    unlockAllBtn:SetText("|cffffaa00Unlock All|r")
    unlockAllBtn:SetScript("OnClick", UnlockAllCurrent)

    local lockAllBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lockAllBtn:SetSize(64, 20)
    lockAllBtn:SetPoint("RIGHT", unlockAllBtn, "LEFT", -3, 0)
    lockAllBtn:SetText("|cff00ff00Lock All|r")
    lockAllBtn:SetScript("OnClick", LockAllCurrent)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetPoint("RIGHT", lockAllBtn, "LEFT", -6, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText("Roll'n'Rolling")

    local scroll = CreateFrame("ScrollFrame", "RollNRollingScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -36)
    scroll:SetPoint("BOTTOMRIGHT", -28, 16)
    f.scroll = scroll

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 34, 400)
    scroll:SetScrollChild(content)
    f.content = content

    local recentHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    recentHeader:SetPoint("TOPLEFT", 12, -6)
    recentHeader:SetTextColor(0.35, 0.90, 0.95)
    recentHeader:Hide()
    f.recentHeader = recentHeader

    local talentHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    talentHeader:SetPoint("TOPLEFT", 12, -6)
    talentHeader:SetTextColor(0.85, 0.65, 0.15)
    f.talentHeader = talentHeader

    local noTalentsText = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    noTalentsText:SetText("No active talent points detected.")
    f.noTalentsText = noTalentsText

    local spellHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellHeader:SetPoint("TOPLEFT", 12, -6)
    spellHeader:SetTextColor(0.25, 0.75, 0.40)
    f.spellHeader = spellHeader

    -- Bottom-right resize handle
    local resizeBtn = CreateFrame("Button", nil, f)
    resizeBtn:SetSize(16, 16)
    resizeBtn:SetPoint("BOTTOMRIGHT", -2, 2)
    resizeBtn:SetFrameLevel(f:GetFrameLevel() + 10)
    resizeBtn:EnableMouse(true)
    resizeBtn:RegisterForDrag("LeftButton")

    local resizeTex = resizeBtn:CreateTexture(nil, "OVERLAY")
    resizeTex:SetAllPoints(resizeBtn)
    resizeTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")

    resizeBtn:SetScript("OnEnter", function(self)
        self.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    end)
    resizeBtn.icon = resizeTex

    resizeBtn:SetScript("OnLeave", function(self)
        self.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    end)

    resizeBtn:SetScript("OnDragStart", function(self)
        self.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        f:StartSizing("BOTTOMRIGHT")
    end)

    resizeBtn:SetScript("OnDragStop", function(self)
        self.icon:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        f:StopMovingOrSizing()
        resizeDebounceFrame:Hide()
        ReflowRollNRolling()
    end)

    f:SetScript("OnSizeChanged", function()
        ScheduleResizeReflow()
    end)

    tinsert(UISpecialFrames, "RollNRollingFrame")
    mainFrame = f
    return f
end

local function ToggleMainWindow()
    local f = CreateMainWindow()
    if f:IsShown() then
        f:Hide()
    else
        RefreshRollNRolling()
        f:Show()
    end
end

SLASH_ROLLNROLLING1 = "/rnr"
SLASH_ROLLNROLLING2 = "/learned"
SlashCmdList["ROLLNROLLING"] = ToggleMainWindow

local function HookClasslessFrameEvents()
    if not ClasslessFrame_Freepick or ClasslessFrame_Freepick._rnrHooked then
        return ClasslessFrame_Freepick and ClasslessFrame_Freepick._rnrHooked ~= nil
    end

    ClasslessFrame_Freepick:HookScript("OnShow", function()
        RefreshClasslessSourceCache()
        if mainFrame and mainFrame:IsShown() then
            RefreshRollNRolling()
        end
    end)

    ClasslessFrame_Freepick._rnrHooked = true
    return true
end

local function CreateClasslessIconButton()
    if not ClasslessFrame_Freepick then
        return false
    end

    HookClasslessFrameEvents()

    if ClasslessFrame_Freepick._rnrIconBtn then
        return true
    end

    local btn = CreateFrame("Button", "RollNRollingClasslessIconBtn", ClasslessFrame_Freepick)
    btn:SetSize(24, 24)
    btn:SetFrameStrata(ClasslessFrame_Freepick:GetFrameStrata() or "HIGH")
    btn:SetFrameLevel((ClasslessFrame_Freepick:GetFrameLevel() or 10) + 15)
    btn:SetPoint("TOPRIGHT", ClasslessFrame_Freepick, "TOPRIGHT", -32, -4)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(btn)
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.10, 0.10, 0.14, 0.90)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetPoint("TOPLEFT", -6, 6)
    border:SetPoint("BOTTOMRIGHT", 6, -6)

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    btn:SetScript("OnClick", ToggleMainWindow)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Roll'n'Rolling")
        GameTooltip:AddLine("Click to toggle /rnr overview", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    ClasslessFrame_Freepick._rnrIconBtn = btn
    return true
end

local readyTimer = CreateFrame("Frame")
readyTimer:Hide()
readyTimer.elapsed = 0
readyTimer:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed >= 1.5 then
        sessionReady = true
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
end)

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:RegisterEvent("SPELLS_CHANGED")
loader:RegisterEvent("CHARACTER_POINTS_CHANGED")
loader:RegisterEvent("PLAYER_TALENT_UPDATE")
loader:RegisterEvent("TALENT_POINTS_CHANGE")
loader:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        GetCharLockStore()
        sessionReady = false
        readyTimer.elapsed = 0
        readyTimer:Show()
        CollectLearnedTalents()
        CollectLearnedSpells()
    elseif mainFrame and mainFrame:IsShown() then
        RefreshRollNRolling()
    else
        CollectLearnedTalents()
        CollectLearnedSpells()
    end
    CreateClasslessIconButton()
end)

local attachWatcher = CreateFrame("Frame")
attachWatcher.elapsed = 0
attachWatcher:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 0.25 then return end
    self.elapsed = 0
    if CreateClasslessIconButton() then
        RefreshClasslessSourceCache()
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
end)
