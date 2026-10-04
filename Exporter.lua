-- BuffScribe / Exporter.lua
-- Turns a set of recorded buffs into a WeakAuras group.
--
-- Two output paths, both built from the same table:
--   * WeakAuras.Import(table)  - opens WA's own import/update dialog in game.
--   * a "!WA:2!" string        - for copy/paste and sharing.
--
-- Everything here is matched against the WeakAuras 4.0.0 that ships with this
-- client (Interface/AddOns/WeakAuras):
--   Transmission.lua:461    WeakAuras.Import accepts a raw table {d=,c=,v=,s=}
--   Transmission.lua:489    at v < 2000 Import builds controlledChildren itself
--   Transmission.lua:205    serialisation configs used by TableToString
--   WeakAuras.lua:3073      the implicit "show" condition variable
--   RegionTypes/Icon.lua:44 the "desaturate" condition property
--   BuffTrigger2.lua:2623   matchesShowOn = "showAlways"

local ADDON, ns = ...

local Exporter = {}
ns.Exporter = Exporter

-- WA uses the 1421 envelope whenever the group has no nested sub-groups, and at
-- that version Import reconstructs controlledChildren from the children list.
local TRANSMIT_VERSION = 1421

----------------------------------------------------------------------

local function WeakAurasReady()
    if not WeakAuras or not WeakAuras.Import then
        ns.Error("WeakAuras is not loaded, so there is nothing to export into.")
        return false
    end
    return true
end

-- Avoid colliding with an aura the user already has.
local function UniqueId(base)
    if not (WeakAuras and WeakAuras.GetData) then return base end
    if not WeakAuras.GetData(base) then return base end
    local n = 2
    while WeakAuras.GetData(base .. " " .. n) do
        n = n + 1
    end
    return base .. " " .. n
end

----------------------------------------------------------------------
-- Aura construction
----------------------------------------------------------------------

local function BuildChild(rec, groupId, xOffset, class)
    local cfg = ns.cfg

    local child = {
        id             = rec.name or ("Spell " .. rec.spellId),
        uid            = WeakAuras.GenerateUniqueID(),
        internalVersion = WeakAuras.InternalVersion(),
        regionType     = "icon",
        parent         = groupId,

        width          = cfg.iconSize,
        height         = cfg.iconSize,
        cooldown       = true,          -- swipe shows the remaining duration
        cooldownEdge   = false,
        icon           = true,
        desaturate     = false,
        alpha          = 1.0,

        selfPoint      = "CENTER",
        anchorPoint    = "CENTER",
        anchorFrameType = "SCREEN",
        xOffset        = xOffset,
        yOffset        = 0,
        frameStrata    = 1,

        triggers = {
            {
                trigger = {
                    type            = "aura2",
                    unit            = "player",
                    debuffType      = rec.isHelpful and "HELPFUL" or "HARMFUL",
                    useExactSpellId = true,
                    auraspellids    = { tostring(rec.spellId) },
                    -- Keeps the icon on screen when the buff is down, so the row
                    -- never reflows and each slot stays where you learned it.
                    matchesShowOn   = "showAlways",
                },
                untrigger = {},
            },
        },

        -- "trigger 1 is not Active" -> grey the icon out and dim it.
        conditions = {
            {
                check = {
                    trigger  = 1,
                    variable = "show",
                    value    = 0,
                },
                changes = {
                    { property = "desaturate", value = cfg.inactiveGrey and true or false },
                    { property = "alpha",      value = cfg.inactiveAlpha },
                },
            },
        },

        subRegions = {
            {
                type             = "subtext",
                text_text        = "%p",     -- remaining time
                text_selfPoint   = "AUTO",
                text_anchorPoint = "BOTTOM",
            },
        },

        load = {},
    }

    -- Stack counter, only where the buff actually stacks.
    if (rec.maxStacks or 0) > 1 then
        table.insert(child.subRegions, {
            type             = "subtext",
            text_text        = "%s",
            text_selfPoint   = "AUTO",
            text_anchorPoint = "TOPRIGHT",
        })
    end

    if cfg.restrictToClass and class then
        child.load = {
            use_class = true,
            class     = { single = class, multi = {} },
        }
    end

    return child
end

-- records: array of recorded buff entries, in display order.
-- Returns parent, children.
function Exporter:BuildAuraTables(records, title, class)
    local cfg     = ns.cfg
    local groupId = UniqueId(title)

    local parent = {
        id              = groupId,
        uid             = WeakAuras.GenerateUniqueID(),
        internalVersion = WeakAuras.InternalVersion(),
        regionType      = "group",
        anchorPoint     = "CENTER",
        anchorFrameType = "SCREEN",
        xOffset         = 0,
        yOffset         = 0,
        scale           = 1,
        -- controlledChildren is deliberately left unset: at TRANSMIT_VERSION
        -- WeakAuras.Import fills it in from the children list itself.
    }

    local children = {}
    local n        = #records
    local step     = cfg.iconSize + cfg.iconSpacing

    for i = 1, n do
        local xOffset = (i - (n + 1) / 2) * step
        children[i]   = BuildChild(records[i], groupId, xOffset, class)
    end

    return parent, children
end

local function Envelope(parent, children)
    return {
        m = "d",
        d = parent,
        c = children,
        v = TRANSMIT_VERSION,
        s = WeakAuras.versionString,
    }
end

----------------------------------------------------------------------
-- Output paths
----------------------------------------------------------------------

-- Hands the aura to WeakAuras' own import dialog so the user confirms it and
-- can diff it against an aura they already have.
function Exporter:Import(records, title, class)
    if not WeakAurasReady() then return end
    if not records or #records == 0 then
        ns.Error("nothing selected - tick at least one buff first.")
        return
    end

    local parent, children = self:BuildAuraTables(records, title, class)
    local ok, err = WeakAuras.Import(Envelope(parent, children))

    if ok == nil and err then
        ns.Error("WeakAuras rejected the import: %s", tostring(err))
        return
    end

    ns.Print("sent |cffffff00%s|r (%d icon(s)) to the WeakAuras import window.",
             parent.id, #children)
end

-- Mirrors WeakAuras' TableToString (Transmission.lua:255) so the string is
-- byte-for-byte the format WA itself produces.
function Exporter:ToString(records, title, class)
    if not WeakAurasReady() then return nil end

    local LibSerialize = LibStub and LibStub:GetLibrary("LibSerialize", true)
    local LibDeflate   = LibStub and LibStub:GetLibrary("LibDeflate", true)
    if not (LibSerialize and LibDeflate) then
        ns.Error("LibSerialize/LibDeflate not found; cannot build an export string.")
        return nil
    end

    local parent, children = self:BuildAuraTables(records, title, class)

    local serialized = LibSerialize:SerializeEx(
        { errorOnUnserializableType = false },
        Envelope(parent, children)
    )
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })

    return "!WA:2!" .. LibDeflate:EncodeForPrint(compressed)
end

----------------------------------------------------------------------
-- Convenience entry points
----------------------------------------------------------------------

function Exporter:DefaultTitle(session)
    local label = session and session.className
    if not label then
        local class = session and session.class
        label = class and (class:sub(1, 1) .. class:sub(2):lower()) or "Snapshot"
    end
    return "BuffScribe - " .. label .. " Snapshot"
end

function Exporter:BuildFromSelection()
    if not ns.UI then return end
    local records, session = ns.UI:GetSelectedRecords()
    if not records or #records == 0 then
        ns.Error("nothing selected - tick at least one buff first.")
        return
    end
    self:Import(records, self:DefaultTitle(session), session and session.class)
end

function Exporter:StringFromSelection()
    if not ns.UI then return nil end
    local records, session = ns.UI:GetSelectedRecords()
    if not records or #records == 0 then
        ns.Error("nothing selected - tick at least one buff first.")
        return nil
    end
    return self:ToString(records, self:DefaultTitle(session), session and session.class)
end
