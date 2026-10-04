# BuffScribe

Records every buff that lands on you during a target-dummy session, then builds a
WeakAuras snapshot tracker out of what it actually saw.

Built for **WoW 3.3.5a (WotLK)** and the **WeakAuras 4.0.0** backport that ships with
this client.

## Why

`Summon Gargoyle` snapshots your stats and attack speed at the instant you cast it —
the pet keeps those numbers for its whole duration. A good Gargoyle therefore means
casting while the right pile of procs happens to be up at once: Unholy Strength,
Icy Talons, Black Magic, Hyperspeed Accelerators, a trinket proc, Bloodlust, a potion.

The hard part is knowing *which* procs your current gear can even produce, and then
seeing them at a glance in the half-second where the decision is made.

BuffScribe answers both: record a dummy session, see everything that fired and what it
was worth, tick the ones that matter, get a WeakAura.

The same applies to any snapshotting ability — the cast capture is configurable.

## Install

```sh
./deploy.sh
```

Copies the addon into `Interface/AddOns/BuffScribe`. Override the client path with
`WOW_DIR=/path/to/wow ./deploy.sh`.

## Use

| Command | Does |
|---|---|
| `/bs` | open / close the window |
| `/bs rec` | start recording |
| `/bs stop` | stop recording |
| `/bs status` | what is being recorded right now |
| `/bs clear` | delete stored sessions for this character |
| `/bs export` | build a WeakAura from the current tick selection |
| `/bs snapshot <spellId>` | also capture casts of another spell |

1. Stand at a training dummy, open BuffScribe, press **Record**.
2. Run a full rotation — pop trinkets, potions, your burst cooldowns.
3. Cast **Summon Gargoyle** at some point. Each cast is captured as a *snapshot*.
4. Press **Stop**.
5. The **Buffs** tab lists everything that landed on you. Snapshot-relevant procs are
   pre-ticked.
6. Press **Build WeakAura**. WeakAuras' own import window opens, you confirm, done.

**Copy import string** gives you the normal `!WA:2!` text instead, for sharing or for
pasting into a different character's WeakAuras.

### The Snapshots tab

Every captured Summon Gargoyle cast, with the buffs that were up at that exact instant
and your AP at the time. Click one and **the buffs from that cast become your tick
selection** — the most direct way to build a tracker around what you actually had up on
your real casts.

## What you get

A WeakAuras group: a fixed, centred row of icons, one per tracked buff.

```
[Unholy Str][Black Magic][Hyperspeed][Trinket]
    6.2s         dim         dim        4.1s
```

Each icon always occupies its slot, so positions never move and you learn them by
muscle memory. When the buff is down the icon is desaturated and dimmed to 50%; when
it is up it is bright with a cooldown swipe counting the remaining time. Buffs that
stack also get a stack counter.

Implemented as `matchesShowOn = "showAlways"` plus a condition on the trigger's
implicit `show` variable driving `desaturate` and `alpha`. Each icon triggers on the
**exact spell ID** that was recorded, not on a name, so rank and same-name collisions
are not an issue.

## How a buff gets flagged relevant

Two layers, and the second is the one that matters:

1. **A curated list** of known WotLK snapshot buffs, keyed by *buff name*. Names, not
   spell IDs — the IDs for enchant and trinket procs are easy to get subtly wrong, and
   a wrong ID would silently mis-tag a buff. The recorder captures the real spell ID at
   runtime regardless, so the generated aura is still exact-ID based.

2. **Measurement.** On every aura change the addon samples attack power, melee haste,
   Strength, crit and swing speed. When exactly one aura changed, the whole stat delta
   is attributed to it. Anything that measurably moved a stat is flagged relevant
   whether or not it is on the list — so a proc from gear the list has never seen still
   gets caught, and a cosmetic buff that moves nothing does not.

Permanent auras (`duration == 0`) and anything lasting over 120 seconds are recorded and
tagged, but not pre-ticked: they are raid buffs, not procs.

## Caveats

- It records what lands on you **as an aura**. Snapshot contributions that are not auras
  — a weapon swap, raw gear stats — will not show up as entries. The snapshot log partly
  covers this by recording your absolute AP at each cast.
- Stat attribution is only trustworthy when a single aura changed in the sampling
  window. During a heavy multi-proc burst several buffs land together and the delta
  cannot be split; those keep whichever cleaner measurement they got elsewhere in the
  session.
- Buffs already active when you press Record are marked `(pre)` and have an application
  count of 0 — they were not observed to proc during the session.

## Files

| File | Role |
|---|---|
| `Core.lua` | saved variables, event frame, slash commands |
| `Classify.lua` | relevance list + the measurement heuristic |
| `Recorder.lua` | aura scanning, combat log, stat sampling, cast snapshots |
| `Exporter.lua` | builds the WeakAuras group; import + `!WA:2!` string |
| `UI.lua` | the window |
