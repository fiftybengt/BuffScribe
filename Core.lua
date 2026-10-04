-- BuffScribe / Core.lua
-- Addon table, saved-variable handling, the shared event frame and slash commands.

local ADDON, ns = ...

ns.ADDON   = ADDON
ns.VERSION = "1.0"

local DB_VERSION = 1

-- Default configuration. Stored globally (not per character) because these are
-- preferences about how the addon behaves, not data about a character.
local defaults = {
    snapshotSpells   = { 49206 },  -- Summon Gargoyle
    autoStartOnDummy = false,
    sampleInterval   = 0.5,        -- seconds between passive stat samples
    attributeDelay   = 0.15,       -- wait this long after an aura change before measuring stats
    iconSize         = 40,
    iconSpacing      = 4,
    inactiveAlpha    = 0.5,   -- opacity of an icon whose buff is not up
    inactiveGrey     = true,  -- also desaturate it
    restrictToClass  = true,
    maxSessions      = 10,
}
ns.defaults = defaults

----------------------------------------------------------------------
-- Output helpers
----------------------------------------------------------------------

local PREFIX = "|cff66ccffBuffScribe|r: "

function ns.Print(fmt, ...)
    local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns.Error(fmt, ...)
    local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cffff5555" .. msg .. "|r")
end

----------------------------------------------------------------------
-- Database
----------------------------------------------------------------------

function ns.CharKey()
    local name  = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return name .. "-" .. realm
end

local function InitDB()
    if type(BuffScribeDB) ~= "table" then
        BuffScribeDB = {}
    end

    BuffScribeDB.version = BuffScribeDB.version or DB_VERSION
    BuffScribeDB.config  = BuffScribeDB.config or {}
    BuffScribeDB.chars   = BuffScribeDB.chars or {}

    -- Fill in any config key added by a later version of the addon.
    for k, v in pairs(defaults) do
        if BuffScribeDB.config[k] == nil then
            if type(v) == "table" then
                local copy = {}
                for i = 1, #v do copy[i] = v[i] end
                BuffScribeDB.config[k] = copy
            else
                BuffScribeDB.config[k] = v
            end
        end
    end

    local key = ns.CharKey()
    BuffScribeDB.chars[key] = BuffScribeDB.chars[key] or {}
    BuffScribeDB.chars[key].sessions = BuffScribeDB.chars[key].sessions or {}

    ns.db   = BuffScribeDB
    ns.cfg  = BuffScribeDB.config
    ns.char = BuffScribeDB.chars[key]
end

-- Only call after ADDON_LOADED.
function ns.Sessions()
    return ns.char and ns.char.sessions or {}
end

----------------------------------------------------------------------
-- Shared event frame + OnUpdate driver
----------------------------------------------------------------------

local frame = CreateFrame("Frame", "BuffScribeEventFrame", UIParent)
ns.frame = frame

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local which = ...
        if which == ADDON then
            InitDB()
            ns.loaded = true
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        -- UnitName is only reliable from here on, so re-key the character table.
        InitDB()
        if ns.Recorder and ns.Recorder.Init then ns.Recorder:Init() end
        if ns.UI and ns.UI.Init then ns.UI:Init() end
        ns.Print("loaded. |cffffff00/bs|r to open, |cffffff00/bs rec|r to start recording.")
        return
    end

    if event == "PLAYER_LOGOUT" then
        if ns.Recorder and ns.Recorder.recording then
            ns.Recorder:Stop(true)
        end
        return
    end

    -- Everything else belongs to the recorder.
    if ns.Recorder and ns.Recorder.OnEvent then
        ns.Recorder:OnEvent(event, ...)
    end
end)

frame:SetScript("OnUpdate", function(self, elapsed)
    if ns.Recorder and ns.Recorder.OnUpdate then
        ns.Recorder:OnUpdate(elapsed)
    end
end)

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------

local function Usage()
    ns.Print("commands:")
    ns.Print("  |cffffff00/bs|r            toggle the window")
    ns.Print("  |cffffff00/bs rec|r        start recording a session")
    ns.Print("  |cffffff00/bs stop|r       stop recording")
    ns.Print("  |cffffff00/bs status|r     what is being recorded right now")
    ns.Print("  |cffffff00/bs clear|r      delete all stored sessions for this character")
    ns.Print("  |cffffff00/bs export|r     build a WeakAura from the current selection")
    ns.Print("  |cffffff00/bs snapshot <spellId>|r   add a spell to the cast-capture list")
end

SLASH_BUFFSCRIBE1 = "/bs"
SLASH_BUFFSCRIBE2 = "/buffscribe"

SlashCmdList["BUFFSCRIBE"] = function(input)
    input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        if ns.UI then ns.UI:Toggle() end

    elseif cmd == "rec" or cmd == "record" or cmd == "start" then
        ns.Recorder:Start()

    elseif cmd == "stop" then
        ns.Recorder:Stop()

    elseif cmd == "status" then
        ns.Recorder:Status()

    elseif cmd == "clear" then
        local n = #ns.Sessions()
        for i = n, 1, -1 do ns.Sessions()[i] = nil end
        ns.Print("cleared %d stored session(s).", n)
        if ns.UI then ns.UI:Refresh() end

    elseif cmd == "export" then
        ns.Exporter:BuildFromSelection()

    elseif cmd == "snapshot" then
        local id = tonumber(rest)
        if not id then
            ns.Error("usage: /bs snapshot <spellId>")
        else
            table.insert(ns.cfg.snapshotSpells, id)
            local name = GetSpellInfo(id)
            ns.Print("cast capture will also watch %s (%d).", name or "spell", id)
        end

    else
        Usage()
    end
end
