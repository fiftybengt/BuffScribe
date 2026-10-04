-- BuffScribe / Classify.lua
-- Decides which recorded buffs are worth putting on a snapshot tracker.
--
-- Two layers, deliberately in this order:
--
--   1. A curated set of WotLK buffs that are known to matter for a snapshotted
--      pet (Gargoyle, Army, Shadowfiend, ...). This is keyed by *buff name*, not
--      spell ID. Names are stable and verifiable; the spell IDs for enchant and
--      trinket procs are easy to get subtly wrong, and a wrong ID would silently
--      mis-tag a buff. The recorder captures the real spell ID at runtime anyway,
--      so the generated WeakAura is still exact-ID based.
--
--   2. A measurement heuristic: any buff that demonstrably moved attack power,
--      melee haste, Strength or crit is relevant, whether or not it is listed.
--      This is what makes the addon work on gear the curated list has never seen.

local ADDON, ns = ...

local Classify = {}
ns.Classify = Classify

----------------------------------------------------------------------
-- Curated relevance set (lowercase buff names)
----------------------------------------------------------------------

local KNOWN = {
    -- Death Knight / melee haste
    ["icy talons"]              = true,
    ["improved icy talons"]     = true,
    -- Weapon enchants and tinkers
    ["black magic"]             = true,
    ["berserking"]              = true,  -- both the enchant (AP) and the troll racial (haste)
    ["unholy strength"]         = true,  -- Rune of the Fallen Crusader
    ["hyperspeed acceleration"] = true,
    ["swordguard embroidery"]   = true,
    -- Raid cooldowns and consumables worth lining up
    ["bloodlust"]               = true,
    ["heroism"]                 = true,
    ["potion of speed"]         = true,
    ["potion of wild magic"]    = true,
    ["indestructible"]          = true,
    -- Racials
    ["blood fury"]              = true,
    -- Trinket procs
    ["greatness"]               = true,  -- Darkmoon Card: Greatness
    ["grim toll"]               = true,
    ["agile"]                   = true,  -- Comet's Trail
    ["paragon"]                 = true,  -- Death's Verdict / Death's Choice
    ["pyrite infusion"]         = true,
    ["meteorite whetstone"]     = true,
    ["fury of the five flights"]= true,
    ["mirror of truth"]         = true,
    ["reflection of torment"]   = true,
    ["incisor fragment"]        = true,
    ["mark of supremacy"]       = true,
    ["blood of the old god"]    = true,
    ["sting"]                   = true,  -- Needle-Encrusted Scorpion
    ["manifest anger"]          = true,  -- Tiny Abomination in a Jar
    ["banner of victory"]       = true,
    ["show of faith"]           = true,
    ["victor's call"]           = true,
    ["dark matter"]             = true,
    ["strength of the taunka"]  = true,  -- Deathbringer's Will
    ["agility of the vrykul"]   = true,
    ["power of the taunka"]     = true,
    ["aim of the iron dwarves"] = true,
    ["speed of the vrykul"]     = true,
    ["sharpened twilight scale"]= true,
    ["herkuml war token"]       = true,
    ["muradin's spyglass"]      = true,
    ["deathbringer's will"]     = true,
}

-- Buffs that are never interesting on a snapshot tracker even though they are
-- temporary and may move a stat.
local EXCLUDE_PATTERNS = {
    "^well fed",
    "^food$",
    "^drink$",
    "^flask of",
    "^elixir of",
    "^guardian elixir",
    "^battle elixir",
    "^rested$",
    "^sated$",            -- Bloodlust/Heroism debuff
    "^exhaustion$",
    "^recently bandaged",
    "^ghost$",
    "^resurrection sickness",
}

----------------------------------------------------------------------
-- Thresholds for "this buff measurably did something"
----------------------------------------------------------------------

local THRESHOLD = {
    ap    = 100,    -- attack power
    haste = 1.0,    -- percent melee haste
    str   = 20,     -- Strength
    crit  = 0.5,    -- percent melee crit
    speed = 0.02,   -- seconds of main-hand swing time (fallback if GetMeleeHaste is absent)
}

-- Any buff lasting longer than this is treated as a sustained raid buff rather
-- than a proc, and is not pre-ticked even if it is relevant.
local PROC_MAX_DURATION = 120

Classify.THRESHOLD        = THRESHOLD
Classify.PROC_MAX_DURATION = PROC_MAX_DURATION

----------------------------------------------------------------------

local function IsExcluded(name)
    local lower = (name or ""):lower()
    for i = 1, #EXCLUDE_PATTERNS do
        if lower:find(EXCLUDE_PATTERNS[i]) then
            return true
        end
    end
    return false
end

function Classify.IsKnown(name)
    return KNOWN[(name or ""):lower()] == true
end

-- Turn a measured stat delta into a short tag. Picks the single largest mover so
-- the UI stays scannable; returns nil when nothing crossed its threshold.
function Classify.TagFromDelta(delta)
    if not delta then return nil end

    local best, bestTag, bestText

    local function consider(value, threshold, tag, text)
        if not value then return end
        local magnitude = math.abs(value) / threshold
        if magnitude >= 1 and (not best or magnitude > best) then
            best, bestTag, bestText = magnitude, tag, text
        end
    end

    consider(delta.ap,    THRESHOLD.ap,    "AP",    delta.ap    and string.format("%+d AP",      delta.ap))
    consider(delta.haste, THRESHOLD.haste, "HASTE", delta.haste and string.format("%+.1f%% hst", delta.haste))
    consider(delta.str,   THRESHOLD.str,   "STR",   delta.str   and string.format("%+d Str",     delta.str))
    consider(delta.crit,  THRESHOLD.crit,  "CRIT",  delta.crit  and string.format("%+.1f%% crit",delta.crit))

    -- Only fall back to raw swing speed when haste reporting was unavailable.
    if not bestTag and delta.haste == nil then
        consider(delta.speed, THRESHOLD.speed, "HASTE",
                 delta.speed and string.format("%+.2fs swing", delta.speed))
    end

    return bestTag, bestText
end

-- Full verdict for one recorded buff.
-- Returns: relevant (bool), tag (string), reason (string), deltaText (string or nil)
function Classify.Evaluate(rec)
    if not rec then return false, "OTHER", "none" end

    if rec.permanent then
        return false, "PASSIVE", "permanent"
    end

    if IsExcluded(rec.name) then
        return false, "OTHER", "excluded"
    end

    local tag, deltaText = Classify.TagFromDelta(rec.delta)
    local known          = Classify.IsKnown(rec.name)
    local measured       = tag ~= nil
    local isProc         = (rec.maxDuration or 0) > 0 and (rec.maxDuration or 0) <= PROC_MAX_DURATION

    if not tag then
        tag = known and "KNOWN" or "OTHER"
    end

    if (known or measured) and isProc then
        return true, tag, measured and "measured" or "known", deltaText
    end

    -- Relevant but long-lasting: a raid buff or a self-maintained aura. Shown,
    -- tagged, but not pre-ticked.
    if known or measured then
        return false, tag, "sustained", deltaText
    end

    return false, "OTHER", "none", deltaText
end

-- Colours for the tag column.
local TAG_COLOR = {
    HASTE   = "ffffd100",
    AP      = "ffff7d0a",
    STR     = "ffc79c6e",
    CRIT    = "ffabd473",
    KNOWN   = "ff69ccf0",
    PASSIVE = "ff808080",
    OTHER   = "ff9d9d9d",
}

function Classify.Colorize(tag)
    return "|c" .. (TAG_COLOR[tag] or TAG_COLOR.OTHER) .. (tag or "?") .. "|r"
end
