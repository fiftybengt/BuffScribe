-- BuffScribe / UI.lua
-- The recorder window: record control, the recorded-buff checklist, the
-- snapshot log, and the two export buttons.
--
-- Plain frames only, no libraries, so the addon has nothing to keep in sync
-- with the rest of the client.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

UI.selectedSession = 1       -- index into the stored session list
UI.selected        = {}      -- spellId -> true
UI.tab             = "buffs"
UI.snapshotIndex   = nil

local NUM_ROWS      = 12
local ROW_HEIGHT    = 22
local NUM_SNAP_ROWS = 10
local SNAP_HEIGHT   = 26

local BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 32,
    insets   = { left = 11, right = 12, top = 12, bottom = 11 },
}

----------------------------------------------------------------------
-- Session / record helpers
----------------------------------------------------------------------

function UI:CurrentSession()
    if ns.Recorder.recording then
        return ns.Recorder.session, true
    end
    local sessions = ns.Sessions()
    return sessions[self.selectedSession], false
end

-- Flat, sorted list of the current session's records, most interesting first.
function UI:BuildRowList()
    local session = self:CurrentSession()
    local rows = {}
    if not session then
        self.rows = rows
        return rows
    end

    for _, rec in pairs(session.buffs) do
        local relevant, tag, reason, deltaText = ns.Classify.Evaluate(rec)
        rec._relevant  = relevant
        rec._tag       = tag
        rec._reason    = reason
        rec._deltaText = deltaText
        rows[#rows + 1] = rec
    end

    table.sort(rows, function(a, b)
        if a._relevant ~= b._relevant then return a._relevant end
        if (a.uptime or 0) ~= (b.uptime or 0) then return (a.uptime or 0) > (b.uptime or 0) end
        return (a.name or "") < (b.name or "")
    end)

    self.rows = rows
    return rows
end

-- Called when a new session becomes the displayed one: pre-tick the buffs that
-- are worth putting on a snapshot tracker.
function UI:OnSessionLoaded()
    self.selected      = {}
    self.snapshotIndex = nil
    for _, rec in ipairs(self:BuildRowList()) do
        if rec._relevant then
            self.selected[rec.spellId] = true
        end
    end
    self:Refresh()
end

function UI:GetSelectedRecords()
    local session = self:CurrentSession()
    if not session then return {}, nil end

    local out = {}
    for _, rec in ipairs(self:BuildRowList()) do
        if self.selected[rec.spellId] then
            out[#out + 1] = rec
        end
    end
    return out, session
end

----------------------------------------------------------------------
-- Small widget helpers
----------------------------------------------------------------------

local function MakeButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeLabel(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function FormatDuration(seconds)
    if not seconds or seconds <= 0 then return "-" end
    if seconds >= 60 then
        return string.format("%dm", math.floor(seconds / 60 + 0.5))
    end
    return string.format("%ds", math.floor(seconds + 0.5))
end

----------------------------------------------------------------------
-- Export-string window
----------------------------------------------------------------------

function UI:ShowString(str)
    if not self.stringFrame then
        local f = CreateFrame("Frame", "BuffScribeStringFrame", UIParent)
        f:SetWidth(520); f:SetHeight(220)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        f:SetBackdrop(BACKDROP)
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local title = MakeLabel(f, "GameFontNormal")
        title:SetPoint("TOP", f, "TOP", 0, -16)
        title:SetText("WeakAuras import string - press Ctrl+C")

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

        local scroll = CreateFrame("ScrollFrame", "BuffScribeStringScroll", f,
                                   "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -44)
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 20)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(440)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)

        f.edit = edit
        self.stringFrame = f
    end

    self.stringFrame:Show()
    self.stringFrame.edit:SetText(str or "")
    self.stringFrame.edit:HighlightText()
    self.stringFrame.edit:SetFocus()
end

----------------------------------------------------------------------
-- Buff rows
----------------------------------------------------------------------

local function BuffRow_OnEnter(self)
    if not self.spellId then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("spell:" .. self.spellId)
    GameTooltip:Show()
end

local function BuffRow_OnLeave()
    GameTooltip:Hide()
end

function UI:CreateBuffRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(540)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    check:SetWidth(22); check:SetHeight(22)
    check:SetPoint("LEFT", row, "LEFT", 2, 0)
    check:SetScript("OnClick", function(btn)
        if not row.spellId then return end
        UI.selected[row.spellId] = btn:GetChecked() and true or nil
        UI:RefreshHeader()
    end)
    row.check = check

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(18); icon:SetHeight(18)
    icon:SetPoint("LEFT", row, "LEFT", 28, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.icon = icon

    local name = MakeLabel(row)
    name:SetPoint("LEFT", row, "LEFT", 52, 0)
    name:SetWidth(168)
    row.nameText = name

    local info = MakeLabel(row, "GameFontDisableSmall")
    info:SetPoint("LEFT", row, "LEFT", 222, 0)
    info:SetWidth(176)
    row.info = info

    local delta = MakeLabel(row, "GameFontNormalSmall")
    delta:SetPoint("LEFT", row, "LEFT", 400, 0)
    delta:SetWidth(76)
    row.delta = delta

    local tag = MakeLabel(row, "GameFontNormalSmall", "RIGHT")
    tag:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    tag:SetWidth(58)
    row.tag = tag

    -- Hovering the whole row shows the spell tooltip.
    row:SetScript("OnEnter", BuffRow_OnEnter)
    row:SetScript("OnLeave", BuffRow_OnLeave)

    return row
end

----------------------------------------------------------------------
-- Snapshot rows
----------------------------------------------------------------------

function UI:CreateSnapRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(540)
    row:SetHeight(SNAP_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * SNAP_HEIGHT)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    local title = MakeLabel(row, "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -2)
    title:SetWidth(300)
    row.title = title

    local detail = MakeLabel(row, "GameFontDisableSmall")
    detail:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 2)
    detail:SetWidth(520)
    row.detail = detail

    row:SetScript("OnClick", function()
        if not row.snapIndex then return end
        UI.snapshotIndex = row.snapIndex
        UI:ApplySnapshotSelection(row.snapIndex)
    end)

    return row
end

-- Tick exactly the buffs that were up at the moment of a captured cast.
function UI:ApplySnapshotSelection(index)
    local session = self:CurrentSession()
    if not session then return end
    local snap = session.snapshots[index]
    if not snap then return end

    self.selected = {}
    for _, a in ipairs(snap.auras) do
        self.selected[a.spellId] = true
    end

    ns.Print("selected the %d buff(s) that were up on %s.", #snap.auras, snap.spellName)
    self.tab = "buffs"
    self:Refresh()
end

----------------------------------------------------------------------
-- Frame construction
----------------------------------------------------------------------

function UI:Init()
    if self.frame then return end

    local f = CreateFrame("Frame", "BuffScribeFrame", UIParent)
    f:SetWidth(620); f:SetHeight(450)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetBackdrop(BACKDROP)
    f:SetFrameStrata("MEDIUM")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnShow", function() UI:Refresh() end)
    f:Hide()
    tinsert(UISpecialFrames, "BuffScribeFrame")   -- Escape closes it
    self.frame = f

    local title = MakeLabel(f, "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -16)
    title:SetText("BuffScribe")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)

    -- Record control -------------------------------------------------
    self.recButton = MakeButton(f, "Record", 90, function()
        if ns.Recorder.recording then ns.Recorder:Stop() else ns.Recorder:Start() end
    end)
    self.recButton:SetPoint("TOPLEFT", f, "TOPLEFT", 100, -12)

    self.status = MakeLabel(f, "GameFontHighlightSmall")
    self.status:SetPoint("LEFT", self.recButton, "RIGHT", 10, 0)
    self.status:SetWidth(320)

    -- Session picker -------------------------------------------------
    self.prevBtn = MakeButton(f, "<", 24, function() UI:StepSession(1) end)
    self.prevBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -42)

    self.sessionLabel = MakeLabel(f, "GameFontNormalSmall", "CENTER")
    self.sessionLabel:SetPoint("LEFT", self.prevBtn, "RIGHT", 4, 0)
    self.sessionLabel:SetWidth(240)

    self.nextBtn = MakeButton(f, ">", 24, function() UI:StepSession(-1) end)
    self.nextBtn:SetPoint("LEFT", self.sessionLabel, "RIGHT", 4, 0)

    -- Tabs -----------------------------------------------------------
    self.buffsTab = MakeButton(f, "Buffs", 80, function()
        UI.tab = "buffs"; UI:Refresh()
    end)
    self.buffsTab:SetPoint("TOPRIGHT", f, "TOPRIGHT", -108, -42)

    self.snapsTab = MakeButton(f, "Snapshots", 90, function()
        UI.tab = "snapshots"; UI:Refresh()
    end)
    self.snapsTab:SetPoint("LEFT", self.buffsTab, "RIGHT", 4, 0)

    -- Column headers -------------------------------------------------
    local header = MakeLabel(f, "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 70, -70)
    header:SetText("Buff")
    self.colHeader = header

    local header2 = MakeLabel(f, "GameFontNormalSmall")
    header2:SetPoint("TOPLEFT", f, "TOPLEFT", 240, -70)
    header2:SetText("seen / stacks / dur / uptime")
    self.colHeader2 = header2

    local header3 = MakeLabel(f, "GameFontNormalSmall")
    header3:SetPoint("TOPLEFT", f, "TOPLEFT", 418, -70)
    header3:SetText("measured")
    self.colHeader3 = header3

    -- Buff list ------------------------------------------------------
    local listHolder = CreateFrame("Frame", nil, f)
    listHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -86)
    listHolder:SetWidth(570)
    listHolder:SetHeight(NUM_ROWS * ROW_HEIGHT)
    self.listHolder = listHolder

    self.buffScroll = CreateFrame("ScrollFrame", "BuffScribeBuffScroll", listHolder,
                                  "FauxScrollFrameTemplate")
    self.buffScroll:SetPoint("TOPLEFT", listHolder, "TOPLEFT", 0, 0)
    self.buffScroll:SetPoint("BOTTOMRIGHT", listHolder, "BOTTOMRIGHT", -26, 0)
    self.buffScroll:SetScript("OnVerticalScroll", function(frame, offset)
        FauxScrollFrame_OnVerticalScroll(frame, offset, ROW_HEIGHT, function()
            UI:RefreshList()
        end)
    end)

    self.buffRows = {}
    for i = 1, NUM_ROWS do
        self.buffRows[i] = self:CreateBuffRow(listHolder, i)
    end

    -- Snapshot list --------------------------------------------------
    local snapHolder = CreateFrame("Frame", nil, f)
    snapHolder:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -86)
    snapHolder:SetWidth(570)
    snapHolder:SetHeight(NUM_SNAP_ROWS * SNAP_HEIGHT)
    snapHolder:Hide()
    self.snapHolder = snapHolder

    self.snapScroll = CreateFrame("ScrollFrame", "BuffScribeSnapScroll", snapHolder,
                                  "FauxScrollFrameTemplate")
    self.snapScroll:SetPoint("TOPLEFT", snapHolder, "TOPLEFT", 0, 0)
    self.snapScroll:SetPoint("BOTTOMRIGHT", snapHolder, "BOTTOMRIGHT", -26, 0)
    self.snapScroll:SetScript("OnVerticalScroll", function(frame, offset)
        FauxScrollFrame_OnVerticalScroll(frame, offset, SNAP_HEIGHT, function()
            UI:RefreshList()
        end)
    end)

    self.snapRows = {}
    for i = 1, NUM_SNAP_ROWS do
        self.snapRows[i] = self:CreateSnapRow(snapHolder, i)
    end

    -- Footer ---------------------------------------------------------
    local relBtn = MakeButton(f, "Select relevant", 110, function()
        UI.selected = {}
        for _, rec in ipairs(UI:BuildRowList()) do
            if rec._relevant then UI.selected[rec.spellId] = true end
        end
        UI:Refresh()
    end)
    relBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 44)

    local allBtn = MakeButton(f, "All", 50, function()
        for _, rec in ipairs(UI:BuildRowList()) do UI.selected[rec.spellId] = true end
        UI:Refresh()
    end)
    allBtn:SetPoint("LEFT", relBtn, "RIGHT", 4, 0)

    local noneBtn = MakeButton(f, "None", 50, function()
        UI.selected = {}
        UI:Refresh()
    end)
    noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)

    self.countLabel = MakeLabel(f, "GameFontNormalSmall", "RIGHT")
    self.countLabel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 48)
    self.countLabel:SetWidth(200)

    local buildBtn = MakeButton(f, "Build WeakAura", 130, function()
        ns.Exporter:BuildFromSelection()
    end)
    buildBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 16)

    local copyBtn = MakeButton(f, "Copy import string", 140, function()
        local str = ns.Exporter:StringFromSelection()
        if str then UI:ShowString(str) end
    end)
    copyBtn:SetPoint("RIGHT", buildBtn, "LEFT", -4, 0)

    local hint = MakeLabel(f, "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 20)
    hint:SetWidth(280)
    hint:SetText("Tick the buffs to track, then build.")
end

function UI:StepSession(delta)
    local sessions = ns.Sessions()
    if #sessions == 0 then return end
    local new = self.selectedSession + delta
    if new < 1 then new = 1 end
    if new > #sessions then new = #sessions end
    if new ~= self.selectedSession then
        self.selectedSession = new
        self:OnSessionLoaded()
    end
end

function UI:Toggle()
    if not self.frame then self:Init() end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self.frame:Show()
    end
end

----------------------------------------------------------------------
-- Refresh
----------------------------------------------------------------------

function UI:RefreshHeader()
    if not self.frame or not self.frame:IsShown() then return end

    local session, live = self:CurrentSession()

    if ns.Recorder.recording then
        self.recButton:SetText("Stop")
        local elapsed = math.floor(GetTime() - ns.Recorder.session.startedGT)
        self.status:SetText(string.format(
            "|cffff4444REC|r %s  -  %d buff(s), %d snapshot(s)%s",
            SecondsToTime(elapsed),
            ns.Recorder.session.buffCount or 0,
            #ns.Recorder.session.snapshots,
            ns.Recorder.session.target and ("  -  " .. ns.Recorder.session.target) or ""))
    else
        self.recButton:SetText("Record")
        self.status:SetText("Idle. Target a dummy and press Record.")
    end

    local sessions = ns.Sessions()
    if live then
        self.sessionLabel:SetText("|cffff4444live session|r")
    elseif session then
        self.sessionLabel:SetText(string.format("session %d/%d  -  %s  -  %s",
            self.selectedSession, #sessions,
            date("%d %b %H:%M", session.started),
            session.target or "no target"))
    else
        self.sessionLabel:SetText("no sessions recorded yet")
    end

    local n = 0
    for _ in pairs(self.selected) do n = n + 1 end
    self.countLabel:SetText(string.format("%d buff(s) selected", n))
end

function UI:RefreshList()
    if not self.frame or not self.frame:IsShown() then return end

    if self.tab == "buffs" then
        self.listHolder:Show()
        self.snapHolder:Hide()

        local rows = self.rows or {}
        FauxScrollFrame_Update(self.buffScroll, #rows, NUM_ROWS, ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(self.buffScroll)

        for i = 1, NUM_ROWS do
            local row = self.buffRows[i]
            local rec = rows[i + offset]
            if rec then
                row.spellId = rec.spellId
                row.check:SetChecked(self.selected[rec.spellId] and true or false)
                row.icon:SetTexture(rec.icon)

                local label = rec.name or ("Spell " .. rec.spellId)
                if rec.preexisting then
                    label = label .. " |cff808080(pre)|r"
                end
                row.nameText:SetText(label)

                row.info:SetText(string.format("%dx  %s  %s  %s",
                    rec.applications or 0,
                    (rec.maxStacks or 0) > 1 and (rec.maxStacks .. " st") or "-",
                    FormatDuration(rec.maxDuration),
                    FormatDuration(rec.uptime)))

                row.delta:SetText(rec._deltaText or "")
                row.tag:SetText(ns.Classify.Colorize(rec._tag))
                row:Show()
            else
                row.spellId = nil
                row:Hide()
            end
        end

    else
        self.listHolder:Hide()
        self.snapHolder:Show()

        local session = self:CurrentSession()
        local snaps   = session and session.snapshots or {}

        FauxScrollFrame_Update(self.snapScroll, #snaps, NUM_SNAP_ROWS, SNAP_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(self.snapScroll)

        for i = 1, NUM_SNAP_ROWS do
            local row  = self.snapRows[i]
            local idx  = i + offset
            local snap = snaps[idx]
            if snap then
                row.snapIndex = idx
                row.title:SetText(string.format("|cffffff00%s|r  at %s  (%d buffs up)",
                    snap.spellName, FormatDuration(snap.elapsed), #snap.auras))

                local names = {}
                for _, a in ipairs(snap.auras) do
                    if #names < 6 then names[#names + 1] = a.name or "?" end
                end
                local more = (#snap.auras > #names)
                             and string.format(" +%d more", #snap.auras - #names) or ""

                row.detail:SetText(string.format("%d AP  -  %s%s",
                    snap.stats.ap or 0, table.concat(names, ", "), more))
                row:Show()
            else
                row.snapIndex = nil
                row:Hide()
            end
        end
    end
end

function UI:Refresh()
    if not self.frame or not self.frame:IsShown() then return end
    self:BuildRowList()
    self:RefreshHeader()
    self:RefreshList()
end
