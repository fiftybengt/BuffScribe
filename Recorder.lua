-- BuffScribe / Recorder.lua
-- Session recording: aura scanning, combat-log sourcing, stat sampling and
-- cast snapshots.

local ADDON, ns = ...

local Recorder = {}
ns.Recorder = Recorder

Recorder.recording = false
Recorder.session   = nil

-- Live state, valid only while recording.
local active        = {}    -- spellId -> { stacks, expirationTime, duration }
local pendingSource = {}    -- spellId -> sourceName seen in the combat log
local dirty         = false
local lastScan      = 0
local sampleAccum   = 0
local lastSample    = nil
local pendingAttr   = nil   -- { spellId, pre, at }
local playerGUID    = nil

local SCAN_SAFETY_CAP = 80  -- UnitAura index guard; WotLK caps far below this

local DUMMY_PATTERNS = { "training dummy", "target dummy", "practice dummy" }

----------------------------------------------------------------------
-- Stat sampling
----------------------------------------------------------------------

local function Sample()
    local base, pos, neg = UnitAttackPower("player")
    local mainSpeed      = UnitAttackSpeed("player")

    return {
        ap    = (base or 0) + (pos or 0) + (neg or 0),
        speed = mainSpeed,
        str   = select(2, UnitStat("player", 1)),
        -- Guarded: present on 3.3.5a, but a missing one must not break recording.
        crit  = GetCritChance and GetCritChance() or nil,
        haste = GetMeleeHaste and GetMeleeHaste() or nil,
        t     = GetTime(),
    }
end
Recorder.Sample = Sample

local function Diff(pre, post)
    if not pre or not post then return nil end
    local d = {}
    local any = false
    for _, k in ipairs({ "ap", "speed", "str", "crit", "haste" }) do
        if pre[k] and post[k] then
            d[k] = post[k] - pre[k]
            any = true
        end
    end
    return any and d or nil
end

-- Keep whichever measurement showed the larger effect; a proc caught mid-fight
-- can be partially masked by another buff falling off in the same window.
local function DeltaMagnitude(d)
    if not d then return 0 end
    local T = ns.Classify.THRESHOLD
    local m = 0
    if d.ap    then m = math.max(m, math.abs(d.ap)    / T.ap)    end
    if d.haste then m = math.max(m, math.abs(d.haste) / T.haste) end
    if d.str   then m = math.max(m, math.abs(d.str)   / T.str)   end
    if d.crit  then m = math.max(m, math.abs(d.crit)  / T.crit)  end
    return m
end

----------------------------------------------------------------------
-- Aura scanning
----------------------------------------------------------------------

local function TouchRecord(session, spellId, name, icon, isHelpful, now)
    local rec = session.buffs[spellId]
    if not rec then
        rec = {
            spellId      = spellId,
            name         = name,
            icon         = icon,
            isHelpful    = isHelpful,
            applications = 0,
            refreshes    = 0,
            maxStacks    = 0,
            maxDuration  = 0,
            permanent    = true,
            uptime       = 0,
            firstSeen    = now,
        }
        session.buffs[spellId] = rec
        session.buffCount = (session.buffCount or 0) + 1

        if pendingSource[spellId] then
            rec.sourceName = pendingSource[spellId]
        end
    end
    rec.name = name
    rec.icon = icon
    return rec
end

-- Scans one filter, filling newActive and appending to added/refreshed.
local function ScanFilter(filter, isHelpful, session, now, newActive, added, refreshed)
    local index = 1
    while index <= SCAN_SAFETY_CAP do
        local name, _, icon, stacks, _, duration, expirationTime, unitCaster, _, _, spellId =
            UnitAura("player", index, filter)

        if not name then break end

        if spellId then
            local rec = TouchRecord(session, spellId, name, icon, isHelpful, now)
            rec.lastSeen = now

            stacks = stacks or 0
            if stacks > rec.maxStacks then rec.maxStacks = stacks end

            if duration and duration > 0 then
                rec.permanent = false
                if duration > rec.maxDuration then rec.maxDuration = duration end
            end

            if unitCaster then rec.casterUnit = unitCaster end

            local prev = active[spellId]
            if not prev then
                rec.applications = rec.applications + 1
                added[#added + 1] = spellId
            elseif expirationTime and prev.expirationTime
                   and expirationTime > prev.expirationTime + 0.1 then
                rec.refreshes = rec.refreshes + 1
                refreshed[#refreshed + 1] = spellId
            end

            newActive[spellId] = {
                stacks         = stacks,
                duration       = duration,
                expirationTime = expirationTime,
                name           = name,
                icon           = icon,
            }
        end

        index = index + 1
    end
end

function Recorder:Scan()
    if not self.recording then return end

    local session = self.session
    local now     = GetTime()

    -- Credit uptime for the interval that just ended, before the set changes.
    if lastScan > 0 then
        local elapsed = now - lastScan
        if elapsed > 0 then
            for spellId in pairs(active) do
                local rec = session.buffs[spellId]
                if rec then rec.uptime = (rec.uptime or 0) + elapsed end
            end
        end
    end
    lastScan = now

    local newActive, added, refreshed = {}, {}, {}
    ScanFilter("HELPFUL", true,  session, now, newActive, added, refreshed)
    ScanFilter("HARMFUL", false, session, now, newActive, added, refreshed)

    local removed = 0
    for spellId in pairs(active) do
        if not newActive[spellId] then removed = removed + 1 end
    end

    active = newActive

    local changes = #added + removed
    if changes > 0 then
        -- A second change while a measurement is in flight would contaminate it.
        if pendingAttr then pendingAttr = nil end

        if #added == 1 and removed == 0 and lastSample then
            pendingAttr = {
                spellId = added[1],
                pre     = lastSample,
                at      = now + (ns.cfg.attributeDelay or 0.15),
            }
        end
    end
end

----------------------------------------------------------------------
-- Cast snapshots
----------------------------------------------------------------------

function Recorder:TakeSnapshot(spellId, spellName)
    if not self.recording then return end

    -- A single cast surfaces twice: once in the combat log and once via
    -- UNIT_SPELLCAST_SUCCEEDED. Their order is not guaranteed, so dedupe on
    -- time rather than on which one arrived first.
    local gt = GetTime()
    if self.lastSnapshotSpell == spellId and self.lastSnapshotAt
       and (gt - self.lastSnapshotAt) < 0.5 then
        return
    end
    self.lastSnapshotSpell = spellId
    self.lastSnapshotAt    = gt

    -- Make sure the aura set is current; UNIT_AURA may not have fired this frame.
    self:Scan()

    local now  = GetTime()
    local snap = {
        when      = time(),
        elapsed   = now - self.session.startedGT,
        spellId   = spellId,
        spellName = spellName or (GetSpellInfo(spellId)) or ("spell " .. tostring(spellId)),
        stats     = Sample(),
        auras     = {},
    }

    for id, a in pairs(active) do
        snap.auras[#snap.auras + 1] = {
            spellId   = id,
            name      = a.name,
            icon      = a.icon,
            stacks    = a.stacks,
            remaining = (a.expirationTime and a.expirationTime > 0)
                        and (a.expirationTime - now) or 0,
        }
    end

    table.sort(snap.auras, function(x, y) return (x.name or "") < (y.name or "") end)

    table.insert(self.session.snapshots, snap)
    ns.Print("snapshot: |cffffff00%s|r with %d buff(s) up, %d AP.",
             snap.spellName, #snap.auras, snap.stats.ap or 0)

    if ns.UI then ns.UI:Refresh() end
end

local function IsSnapshotSpell(spellId)
    local list = ns.cfg and ns.cfg.snapshotSpells
    if not list then return false end
    for i = 1, #list do
        if list[i] == spellId then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Session lifecycle
----------------------------------------------------------------------

local RECORD_EVENTS = {
    "UNIT_AURA",
    "COMBAT_LOG_EVENT_UNFILTERED",
    "UNIT_SPELLCAST_SUCCEEDED",
}

function Recorder:Init()
    playerGUID = UnitGUID("player")
    ns.frame:RegisterEvent("PLAYER_TARGET_CHANGED")
end

function Recorder:Start()
    if self.recording then
        ns.Print("already recording. |cffffff00/bs stop|r to finish.")
        return
    end

    playerGUID = UnitGUID("player")

    local session = {
        started   = time(),
        startedGT = GetTime(),
        target    = UnitExists("target") and UnitName("target") or nil,
        class     = select(2, UnitClass("player")),
        className = UnitClass("player"),          -- localised, for display
        charName  = UnitName("player"),
        buffs     = {},
        buffCount = 0,
        snapshots = {},
        gear      = {},
    }
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then session.gear[slot] = link end
    end

    self.session        = session
    self.recording      = true
    self.lastSnapshotAt = nil
    self.lastSnapshotSpell = nil

    active       = {}
    pendingSource = {}
    pendingAttr  = nil
    lastScan     = 0
    sampleAccum  = 0
    lastSample   = Sample()
    session.baseline = lastSample

    for _, e in ipairs(RECORD_EVENTS) do ns.frame:RegisterEvent(e) end

    -- Record what is already up, flagged so it is distinguishable from a proc
    -- that actually fired during the session.
    self:Scan()
    for spellId in pairs(active) do
        local rec = session.buffs[spellId]
        if rec then
            rec.preexisting  = true
            rec.applications = 0
        end
    end

    ns.Print("|cffff4444recording|r started%s.",
             session.target and (" on " .. session.target) or "")
    if ns.UI then ns.UI:Refresh() end
end

function Recorder:Stop(silent)
    if not self.recording then
        if not silent then ns.Print("not recording.") end
        return
    end

    self:Scan()

    for _, e in ipairs(RECORD_EVENTS) do ns.frame:UnregisterEvent(e) end

    local session = self.session
    session.stopped  = time()
    session.duration = GetTime() - session.startedGT

    self.recording = false
    self.session   = nil
    active         = {}
    pendingAttr    = nil

    if session.buffCount and session.buffCount > 0 then
        local sessions = ns.Sessions()
        table.insert(sessions, 1, session)
        local maxN = ns.cfg.maxSessions or 10
        for i = #sessions, maxN + 1, -1 do sessions[i] = nil end

        if ns.UI then
            ns.UI.selectedSession = 1
            ns.UI:OnSessionLoaded()
        end

        if not silent then
            ns.Print("stopped after %s - %d distinct buff(s), %d snapshot(s).",
                     SecondsToTime(math.floor(session.duration)),
                     session.buffCount, #session.snapshots)
        end
    elseif not silent then
        ns.Print("stopped - nothing recorded, session discarded.")
    end

    if ns.UI then ns.UI:Refresh() end
end

function Recorder:Status()
    if not self.recording then
        ns.Print("not recording. %d stored session(s).", #ns.Sessions())
        return
    end
    local s = self.session
    ns.Print("recording for %s - %d buff(s), %d snapshot(s)%s.",
             SecondsToTime(math.floor(GetTime() - s.startedGT)),
             s.buffCount or 0, #s.snapshots,
             s.target and (", target " .. s.target) or "")
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

local function LooksLikeDummy(name)
    if not name then return false end
    local lower = name:lower()
    for i = 1, #DUMMY_PATTERNS do
        if lower:find(DUMMY_PATTERNS[i], 1, true) then return true end
    end
    return false
end

function Recorder:OnEvent(event, ...)
    if event == "UNIT_AURA" then
        local unit = ...
        if unit == "player" then dirty = true end
        return
    end

    if event == "PLAYER_TARGET_CHANGED" then
        if not self.recording and ns.cfg and ns.cfg.autoStartOnDummy
           and LooksLikeDummy(UnitName("target")) then
            self:Start()
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Fallback only. The 3.3.5a event carries a spell *name*, not an ID, so
        -- the combat log below is preferred when it delivers.
        if not self.recording then return end
        local unit, spellName = ...
        if unit ~= "player" or not spellName then return end
        local list = ns.cfg.snapshotSpells
        for i = 1, #list do
            local known = GetSpellInfo(list[i])
            if known and known == spellName then
                self:TakeSnapshot(list[i], spellName)
                break
            end
        end
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not self.recording then return end

        -- 3.3.5a layout: no sourceRaidFlags / destRaidFlags (those are Cataclysm+).
        local _, subevent, sourceGUID, sourceName, _, destGUID, _, _,
              spellId, spellName = ...

        if not subevent or not spellId then return end

        if subevent == "SPELL_CAST_SUCCESS" then
            if sourceGUID == playerGUID and IsSnapshotSpell(spellId) then
                self:TakeSnapshot(spellId, spellName)
            end
            return
        end

        if destGUID ~= playerGUID then return end

        if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH"
           or subevent == "SPELL_AURA_APPLIED_DOSE" then
            -- The aura scan is the source of truth; the combat log only supplies
            -- a reliable caster name, which UnitAura cannot give for items.
            local rec = self.session.buffs[spellId]
            if rec then
                rec.sourceName = sourceName or rec.sourceName
            else
                pendingSource[spellId] = sourceName
            end
            dirty = true
        elseif subevent == "SPELL_AURA_REMOVED" then
            dirty = true
        end
    end
end

function Recorder:OnUpdate(elapsed)
    if not self.recording then return end

    -- UNIT_AURA bursts hard during a burn window; coalesce into one scan a frame.
    if dirty then
        dirty = false
        self:Scan()
    end

    local now = GetTime()

    if pendingAttr and now >= pendingAttr.at then
        local rec  = self.session.buffs[pendingAttr.spellId]
        local post = Sample()
        local d    = Diff(pendingAttr.pre, post)
        if rec and d and DeltaMagnitude(d) > DeltaMagnitude(rec.delta) then
            rec.delta          = d
            rec.deltaConfident = true
        end
        lastSample  = post
        pendingAttr = nil
        if ns.UI then ns.UI:Refresh() end
    end

    sampleAccum = sampleAccum + elapsed
    if sampleAccum >= (ns.cfg.sampleInterval or 0.5) then
        sampleAccum = 0
        if not pendingAttr then
            lastSample = Sample()
        end
        if ns.UI then ns.UI:RefreshHeader() end
    end
end
