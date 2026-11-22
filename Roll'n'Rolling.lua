local addonName = ...
local mainFrame
local iconPool = {}

local ICON_SIZE = 34
local ICON_SPACING = 6
local COLS = 12
local MIN_WIDTH = 380
local MIN_HEIGHT = 240
local MAX_WIDTH = 1100
local MAX_HEIGHT = 900
local unlearnMode = false
local showLabels = false

-- Session tracking so newly rolled spells/talents sort to the front
local recentRollCounter = 0
local knownTalentRanks = nil
local knownSpellNames = nil
local talentRecentOrder = {}
local spellRecentOrder = {}
local sessionReady = false

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

local function IsTexturePath(val)
    if type(val) ~= "string" then return false end
    local lower = val:lower()
    return lower:find("interface\\", 1, true)
        or lower:find("interface/", 1, true)
        or lower:find("%.blp$")
end

local function MatchClassName(text)
    if type(text) ~= "string" or text == "" or IsTexturePath(text) then return nil end
    local lower = text:lower()
    if VALID_CLASSES[lower] then return VALID_CLASSES[lower] end
    for key, properName in pairs(VALID_CLASSES) do
        if lower:find(key, 1, true) then return properName end
    end
    return nil
end

local function ResolveSourceClass(tabName, extraHint)
    local matched = MatchClassName(tabName) or MatchClassName(extraHint)
    if matched then return matched end
    if type(tabName) == "string" and tabName ~= "" and not IsTexturePath(tabName) and tabName:lower() ~= "general" then
        return tabName
    end
    return "Classless"
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

local function ExtractRowIDs(data)
    if type(data) ~= "table" then return {} end
    local ids = {}
    for _, key in ipairs({ "spellID", "currentSpellId", "spellId", "talentId", "talentID", "id" }) do
        if data[key] then
            ids[data[key]] = true
        end
    end
    return ids
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
        tex:SetAllPoints(btn)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn.icon = tex

        local border = btn:CreateTexture(nil, "BACKGROUND")
        border:SetTexture("Interface\\Buttons\\WHITE8X8")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetVertexColor(0.25, 0.25, 0.30, 1)
        btn.border = border

        local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        count:SetPoint("BOTTOMRIGHT", -2, 2)
        btn.count = count

        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
        label:SetWidth(ICON_SIZE + 28)
        label:SetWordWrap(false)
        btn.label = label

        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnDragStart", function(self)
            if unlearnMode then return end
            if self.spellBookId then
                PickupSpell(self.spellBookId, BOOKTYPE_SPELL)
            elseif self.spellName then
                PickupSpell(self.spellName)
            end
        end)

        btn:SetScript("OnClick", function(self)
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
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff66ccffSource:|r " .. FormatNameWithClass(self.spellName, self.className))
            if self.isRecent then
                GameTooltip:AddLine("|cff33ff99Recently Rolled|r")
            end
            if unlearnMode then
                GameTooltip:AddLine("|cffff4444Unlearn Mode Active: Click to unlearn|r")
            end
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        iconPool[index] = btn
    end

    btn:SetParent(parent)
    btn.spellBookId = nil
    btn.spellName = nil
    btn.className = nil
    btn.spellId = nil
    btn.ids = nil
    btn.talentTab = nil
    btn.talentIndex = nil
    btn.isTalent = false
    btn.isRecent = false
    btn.count:SetText("")
    btn.label:SetText("")
    btn.label:Hide()
    btn:Show()
    return btn
end

local function SortRecentFirst(list)
    table.sort(list, function(a, b)
        if a.recentOrder ~= b.recentOrder then
            return a.recentOrder > b.recentOrder
        end
        return a.baseOrder < b.baseOrder
    end)
end

local function CollectLearnedTalents()
    local results = {}
    if not GetNumTalentTabs or not GetNumTalents or not GetTalentInfo then
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
                    className = ResolveSourceClass(tabName),
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
    SortRecentFirst(results)
    return results
end

local function CollectLearnedSpells()
    local byName = {}
    local ordered = {}

    if not GetNumSpellTabs or not GetSpellTabInfo then
        return ordered
    end

    local isBaseline = (knownSpellNames == nil) or (not sessionReady)
    if knownSpellNames == nil then knownSpellNames = {} end

    local currentSpells = {}
    local seq = 0

    for tab = 1, GetNumSpellTabs() do
        local tabName, _, offset, numSpells = GetSpellTabInfo(tab)
        for i = offset + 1, offset + numSpells do
            local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
            local icon = GetSpellTexture(i, BOOKTYPE_SPELL)
            local spellLink = GetSpellLink and GetSpellLink(i, BOOKTYPE_SPELL)
            local spellId = spellLink and tonumber(spellLink:match("spell:(%d+)"))

            if spellName and icon and not IsPassiveSpell(i, BOOKTYPE_SPELL) then
                local key = spellName:lower()
                currentSpells[key] = true

                if not isBaseline and not knownSpellNames[key] then
                    recentRollCounter = recentRollCounter + 1
                    spellRecentOrder[key] = recentRollCounter
                end

                local resolvedClass = ResolveSourceClass(tabName)

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
    SortRecentFirst(ordered)
    return ordered
end

local function ApplyBorderColor(btn, isRecent, defaultR, defaultG, defaultB)
    if unlearnMode then
        btn.border:SetVertexColor(0.90, 0.25, 0.25, 1)
    elseif isRecent then
        btn.border:SetVertexColor(0.35, 0.90, 0.95, 1)
    else
        btn.border:SetVertexColor(defaultR, defaultG, defaultB, 1)
    end
end

function RefreshRollNRolling()
    if not mainFrame then return end

    for _, btn in ipairs(iconPool) do
        btn:Hide()
    end

    local content = mainFrame.content
    local talents = CollectLearnedTalents()
    local spells = CollectLearnedSpells()

    local vSpacing = showLabels and (ICON_SPACING + 16) or ICON_SPACING
    local hSpacing = showLabels and (ICON_SPACING + 26) or ICON_SPACING
    local availWidth = math.max(140, (mainFrame.scroll and mainFrame.scroll:GetWidth() or (mainFrame:GetWidth() - 34)) - 24)
    local cols = math.max(3, math.floor((availWidth + hSpacing) / (ICON_SIZE + hSpacing)))
    content:SetWidth(availWidth)

    mainFrame.talentHeader:SetText(string.format("Learned Talents (%d)", #talents))

    local poolIdx = 0
    local yOffset = -28

    if #talents == 0 then
        mainFrame.noTalentsText:Show()
        mainFrame.noTalentsText:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
        yOffset = yOffset - 26
    else
        mainFrame.noTalentsText:Hide()
        for i, t in ipairs(talents) do
            poolIdx = poolIdx + 1
            local btn = GetIconButton(content, poolIdx)
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + col * (ICON_SIZE + hSpacing), yOffset - row * (ICON_SIZE + vSpacing))
            btn.icon:SetTexture(t.icon)
            ApplyBorderColor(btn, t.recentOrder > 0, 0.85, 0.65, 0.15)
            btn.count:SetText(t.rankText)
            btn.spellName = t.name
            btn.className = t.className
            btn.spellId = t.spellId
            btn.ids = t.ids
            btn.talentTab = t.talentTab
            btn.talentIndex = t.talentIndex
            btn.isTalent = true
            btn.isRecent = (t.recentOrder > 0)
            if showLabels then
                btn.label:SetText(FormatNameWithClass(t.name, t.className))
                btn.label:Show()
            end
        end
        yOffset = yOffset - math.ceil(#talents / cols) * (ICON_SIZE + vSpacing) - 14
    end

    mainFrame.spellHeader:ClearAllPoints()
    mainFrame.spellHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 12, yOffset)
    mainFrame.spellHeader:SetText(string.format("Learned Active Spells (%d)", #spells))
    yOffset = yOffset - 24

    for i, s in ipairs(spells) do
        poolIdx = poolIdx + 1
        local btn = GetIconButton(content, poolIdx)
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", 12 + col * (ICON_SIZE + hSpacing), yOffset - row * (ICON_SIZE + vSpacing))
        btn.icon:SetTexture(s.icon)
        ApplyBorderColor(btn, s.recentOrder > 0, 0.25, 0.75, 0.40)
        btn.spellBookId = s.spellBookId
        btn.spellName = s.name
        btn.className = s.className
        btn.spellId = s.spellId
        btn.ids = s.ids
        btn.isTalent = false
        btn.isRecent = (s.recentOrder > 0)
        if showLabels then
            btn.label:SetText(FormatNameWithClass(s.name, s.className))
            btn.label:Show()
        end
    end

    local spellRows = math.max(1, math.ceil(#spells / cols))
    content:SetHeight(math.abs(yOffset) + spellRows * (ICON_SIZE + vSpacing) + 28)
end

local function CreateMainWindow()
    if mainFrame then return mainFrame end

    local width = 12 + COLS * (ICON_SIZE + ICON_SPACING) + 32
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
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
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
    refresh:SetSize(64, 20)
    refresh:SetPoint("RIGHT", close, "LEFT", -4, 0)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", RefreshRollNRolling)

    local labelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    labelBtn:SetSize(74, 20)
    labelBtn:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
    labelBtn:SetText("Labels: OFF")
    labelBtn:SetScript("OnClick", function(self)
        showLabels = not showLabels
        self:SetText(showLabels and "|cff66ccffLabels: ON|r" or "Labels: OFF")
        RefreshRollNRolling()
    end)

    local modeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    modeBtn:SetSize(96, 20)
    modeBtn:SetPoint("RIGHT", labelBtn, "LEFT", -4, 0)
    modeBtn:SetText("Unlearn: OFF")
    modeBtn:SetScript("OnClick", function(self)
        unlearnMode = not unlearnMode
        self:SetText(unlearnMode and "|cffff4444Unlearn: ON|r" or "Unlearn: OFF")
        f:SetBackdropBorderColor(unlearnMode and 0.85 or 0.28, unlearnMode and 0.20 or 0.28, unlearnMode and 0.20 or 0.34, 1)
        RefreshRollNRolling()
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetPoint("RIGHT", modeBtn, "LEFT", -8, 0)
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

    local talentHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    talentHeader:SetPoint("TOPLEFT", 12, -6)
    f.talentHeader = talentHeader

    local noTalentsText = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    noTalentsText:SetText("No active talent points detected.")
    f.noTalentsText = noTalentsText

    local spellHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    spellHeader:SetPoint("TOPLEFT", 12, -6)
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
        RefreshRollNRolling()
    end)

    f:SetScript("OnSizeChanged", function(self)
        if self:IsShown() then
            RefreshRollNRolling()
        end
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

local function CreateClasslessIconButton()
    if not ClasslessFrame_Freepick or ClasslessFrame_Freepick._rnrIconBtn then
        return ClasslessFrame_Freepick and ClasslessFrame_Freepick._rnrIconBtn ~= nil
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
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
end)