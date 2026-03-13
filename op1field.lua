-- FIELDBOT v3.1
-- algorithmic command center for OP-1 Field
-- deep drum + synth pages: sections, variation, accidents
--
-- PHILOSOPHY:
--   Everything lives in one scale. Sections (verse/chorus/
--   bridge/drop) switch automatically or on demand. Each
--   section has its own energy level, density, velocity
--   curve, and fill probability. The synth generates
--   context-aware melodic phrases that respect the current
--   harmonic moment. Drums breathe with fills, ghost notes,
--   polyrhythm pockets, and euclidean sub-patterns.
--   Happy accidents come from: probability gates, velocity
--   humanisation, micro-timing nudges, occasional wrong
--   notes that are scale-adjacent, and section transitions
--   that sometimes overshoot or lag.
--
-- CONTROLS:
--   E1        → page (DRUM / SYNTH / LFO / PERFORM)
--   E2        → param A
--   E3        → param B
--   K2        → generate / action
--   K3        → mutate / section forward
--   K1 hold   → alt
--   K1 + K2   → play / stop
--   K1 + K3   → reset / panic
--
-- NEW (v3.1):
--   MIDI input: OP-1 Field note_on maps to sections (C2-B2) + root (upper octaves)
--   Pattern record: K1+K2+K3 or hold to capture generative patterns
--   Frozen pattern playback with deterministic generation

local lattice   = require "lattice"
local sequins   = require "sequins"
local musicutil = require "musicutil"

-- ============================================================
-- CONFIG
-- ============================================================
local MIDI_DEV = 1
local OP1_CH   = 1
local CC = {1,2,3,4}
local CC_DEST = {"ENGINE","ENV","FX","VOL"}

local DN = {
  kick=36, snare=38, hat_c=40, hat_o=41,
  clap=43, tom_l=45, tom_h=47, ride=48,
  perc1=50, perc2=52,
}

-- ============================================================
-- SCALES & HARMONY
-- ============================================================
local SCALES = {
  minor      = {0,2,3,5,7,8,10},
  major      = {0,2,4,5,7,9,11},
  dorian     = {0,2,3,5,7,9,10},
  pentatonic = {0,3,5,7,10},
  phrygian   = {0,1,3,5,7,8,10},
  lydian     = {0,2,4,6,7,9,11},
  mixolydian = {0,2,4,5,7,9,10},
  blues      = {0,3,5,6,7,10},
}
local scale_names = {"minor","major","dorian","pentatonic","phrygian","lydian","mixolydian","blues"}

-- Diatonic chord roots for each scale (scale degrees as indices)
-- Used to build progressions
local PROGRESSIONS = {
  -- name = list of {degree, chord_quality}
  -- quality: "m"=minor "M"=major "7"=dom7 "m7"=min7 "sus"=sus4
  verse   = {{1,"m"},{6,"m"},{3,"M"},{7,"m"}},
  chorus  = {{1,"m"},{4,"m"},{5,"M"},{1,"m"}},
  bridge  = {{6,"m"},{3,"M"},{4,"m"},{5,"7"}},
  drop    = {{1,"m"},{1,"m"},{1,"m"},{5,"M"}},
  buildup = {{4,"m"},{5,"M"},{6,"m"},{5,"7"}},
  interlude = {{1,"m"},{7,"m"},{6,"m"},{7,"m"}},
}
local prog_names = {"verse","chorus","bridge","drop","buildup","interlude"}

-- Chord intervals by quality
local CHORD_Q = {
  m={0,3,7}, M={0,4,7}, ["7"]={0,4,7,10},
  m7={0,3,7,10}, sus={0,5,7}, sus2={0,2,7},
}

-- ============================================================
-- SECTIONS
-- ============================================================
-- Each section defines the current musical "moment"
-- and shapes how drums + synth behave
local SECTIONS = {
  {
    name="verse",
    energy=0.4,           -- 0–1: overall intensity
    drum_density=0.45,
    synth_density=0.5,
    velocity_curve="soft", -- soft/medium/hard/accent
    fill_prob=0.1,
    ghost_prob=0.35,
    prog="verse",
    auto_advance=true,    -- auto-move to next section after N bars
    bars=8,
  },
  {
    name="buildup",
    energy=0.65,
    drum_density=0.6,
    synth_density=0.65,
    velocity_curve="medium",
    fill_prob=0.25,
    ghost_prob=0.2,
    prog="buildup",
    auto_advance=true,
    bars=4,
  },
  {
    name="chorus",
    energy=0.85,
    drum_density=0.75,
    synth_density=0.7,
    velocity_curve="hard",
    fill_prob=0.35,
    ghost_prob=0.1,
    prog="chorus",
    auto_advance=true,
    bars=8,
  },
  {
    name="drop",
    energy=0.9,
    drum_density=0.8,
    synth_density=0.45,  -- sparse synth on drop for contrast
    velocity_curve="accent",
    fill_prob=0.5,
    ghost_prob=0.05,
    prog="drop",
    auto_advance=true,
    bars=4,
  },
  {
    name="interlude",
    energy=0.2,
    drum_density=0.25,
    synth_density=0.6,
    velocity_curve="soft",
    fill_prob=0.05,
    ghost_prob=0.45,
    prog="interlude",
    auto_advance=true,
    bars=4,
  },
  {
    name="bridge",
    energy=0.55,
    drum_density=0.5,
    synth_density=0.75,
    velocity_curve="medium",
    fill_prob=0.2,
    ghost_prob=0.25,
    prog="bridge",
    auto_advance=true,
    bars=4,
  },
}
local section_seq = sequins({1,2,3,4,5,6,3,4,1,2,3,4}) -- default journey
-- can be overridden

-- ============================================================
-- PATTERN RECORD MODE
-- ============================================================
local record_mode_active = false
local recorded_drum_pattern = {}   -- [step] = {...notes}
local recorded_synth_pattern = {}  -- [step] = note

local function start_pattern_record()
  record_mode_active = true
  recorded_drum_pattern = {}
  recorded_synth_pattern = {}
  toast("RECORD: capturing pattern")
end

local function stop_pattern_record()
  record_mode_active = false
  toast("PATTERN: recorded & frozen")
end

local function capture_drum_event(step, notes_table)
  if not record_mode_active then return end
  recorded_drum_pattern[step] = notes_table
end

local function capture_synth_event(step, note)
  if not record_mode_active then return end
  recorded_synth_pattern[step] = note
end

-- ============================================================
-- MIDI INPUT SECTION CONTROL
-- ============================================================
local function init_midi_handler()
  if m == nil then return end
  m.event = function(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" then
      local note = msg.note
      -- C2-B2 (24-35): section selection 1-6
      if note >= 24 and note <= 35 then
        local sec_idx = math.min(6, (note - 24) % 12 + 1)
        local sec = SECTIONS[sec_idx]
        if sec then
          section_state.current = sec_idx
          apply_section(sec_idx)
          toast("section: " .. sec.name)
        end
      -- Upper octaves: root note setting (C3+)
      elseif note >= 36 then
        local new_root = ((note - 12) % 12) + 36
        synth.root = util.clamp(new_root, 36, 72)
        rebuild_scale()
        toast("root: " .. musicutil.note_num_to_name(synth.root))
      end
    end
  end
end

-- ============================================================
-- VELOCITY CURVES
-- ============================================================
local function vel_curve(curve, base, rand_range)
  local r = rand_range or 15
  if curve == "soft" then
    return util.clamp(math.floor(base * 0.65 + math.random(-r,r)), 40, 90)
  elseif curve == "medium" then
    return util.clamp(math.floor(base * 0.85 + math.random(-r,r)), 60, 110)
  elseif curve == "hard" then
    return util.clamp(math.floor(base * 1.0  + math.random(-r,r)), 80, 127)
  elseif curve == "accent" then
    -- bimodal: either very soft or very loud
    if math.random() < 0.3 then
      return math.random(30, 60)
    else
      return math.random(100, 127)
    end
  end
  return util.clamp(base + math.random(-r, r), 40, 127)
end

-- ============================================================
-- MICRO-TIMING
-- ============================================================
-- Returns a small sleep offset in beats (±) for humanisation
local function micro_timing(energy)
  -- lower energy = more laid-back, higher = tighter
  local max_ms = (1 - energy) * 0.04  -- up to 40ms at low energy
  return (math.random() - 0.5) * max_ms
end

-- ============================================================
-- EUCLIDEAN HELPERS
-- ============================================================
local function gen_euclid(k, n)
  if k <= 0 then return {} end
  local pat, bucket = {}, 0
  for i = 1, n do
    bucket = bucket + k
    if bucket >= n then bucket = bucket - n; table.insert(pat, true)
    else table.insert(pat, false) end
  end
  return pat
end

local function euclid_hit(pat, step)
  if #pat == 0 then return false end
  return pat[((step-1) % #pat) + 1] == true
end

-- ============================================================
-- DRUM ENGINE
-- ============================================================
-- Each voice has a primary pattern + a euclidean ghost layer
-- Fills are generated separately and injected on last 2 steps
-- of a bar when fill_prob fires

local drum_voices = {
  "kick","snare","hat_c","hat_o","clap","tom_l","tom_h","perc1"
}
local drum_voice_notes = {
  kick=DN.kick, snare=DN.snare, hat_c=DN.hat_c, hat_o=DN.hat_o,
  clap=DN.clap, tom_l=DN.tom_l, tom_h=DN.tom_h, perc1=DN.perc1,
}

local drum = {
  steps = 16,
  pattern = {},         -- [step][voice] = true/false
  vels    = {},         -- [step][voice] = 0–127
  ghost   = {},         -- [step][voice] = true/false (ghost layer)
  ghost_v = {},         -- ghost velocities (very soft)
  fill    = {},         -- [step][voice] for current fill
  fill_active = false,
  fill_step = 13,       -- fills start at step 13 (bar-end 2 steps)

  -- per-voice euclidean patterns (complement to main)
  euclid  = {
    hat_c  = gen_euclid(7, 16),
    perc1  = gen_euclid(3, 16),
    tom_l  = gen_euclid(2, 16),
  },

  -- voice enable
  en = {kick=true,snare=true,hat_c=true,hat_o=false,
        clap=true,tom_l=false,tom_h=false,perc1=false},

  -- swing as per-step delay (applied to even 16ths)
  swing_amt = 0,   -- 0–0.15 beat delay

  -- auto-mutate
  auto_mutate = false,
  mutate_interval = 4,
  mutate_count = 0,
  seq_density = nil,

  -- current section values (pulled from SECTIONS)
  density = 0.5,
  velocity_curve = "medium",
  fill_prob = 0.15,
  ghost_prob = 0.3,
}

local function gen_drum_fill(section)
  -- a fill is a burst of hits across the last N steps of the bar
  -- more hits = more energy, shaped by the section
  local f = {}
  for s = 1, drum.steps do f[s] = {} end
  local e = section.energy
  -- fills concentrate in steps 13–16
  for s = drum.fill_step, drum.steps do
    f[s].snare = math.random() < (0.4 + e * 0.4)
    f[s].tom_h = math.random() < (0.3 + e * 0.3)
    f[s].tom_l = math.random() < (0.2 + e * 0.4)
    f[s].kick  = (s == drum.steps) and math.random() < 0.5
    f[s].hat_c = math.random() < (0.5 + e * 0.3)
  end
  return f
end

local function gen_drums(section)
  section = section or SECTIONS[1]
  local d  = section.drum_density
  local vc = section.velocity_curve
  drum.density = d
  drum.velocity_curve = vc
  drum.fill_prob = section.fill_prob
  drum.ghost_prob = section.ghost_prob

  for s = 1, drum.steps do
    drum.pattern[s] = {}
    drum.vels[s]    = {}
    drum.ghost[s]   = {}
    drum.ghost_v[s] = {}
    drum.fill[s]    = {}

    -- kick: strong downbeats, probabilistic off-beats
    local kick_on_beat = (s==1 or s==9)
    local kick_off     = (s==5 or s==13) and math.random() < d * 0.25
    local kick_extra   = math.random() < d * 0.2
    drum.pattern[s].kick = drum.en.kick and (kick_on_beat or kick_off or kick_extra)

    -- snare: 2 and 4, ghost on weak 16ths
    local snare_on = (s==5 or s==13)
    local snare_off= math.random() < d * 0.12
    drum.pattern[s].snare = drum.en.snare and (snare_on or snare_off)

    -- closed hat: euclidean or straight density
    local hat_euclid = euclid_hit(drum.euclid.hat_c, s)
    local hat_fill   = math.random() < (d * 0.6)
    drum.pattern[s].hat_c = drum.en.hat_c and (hat_euclid or hat_fill)

    -- open hat: on offbeats only when hat_c is silent
    drum.pattern[s].hat_o = drum.en.hat_o and
      (not drum.pattern[s].hat_c) and math.random() < 0.15

    -- clap: layered on snare + occasional syncopation
    drum.pattern[s].clap = drum.en.clap and
      (drum.pattern[s].snare and math.random() < 0.5)

    -- toms: euclidean accents
    drum.pattern[s].tom_l = drum.en.tom_l and euclid_hit(drum.euclid.tom_l, s)
    drum.pattern[s].tom_h = drum.en.tom_h and math.random() < d * 0.05
    drum.pattern[s].perc1 = drum.en.perc1 and euclid_hit(drum.euclid.perc1, s)

    -- velocities shaped by curve
    for _,v in ipairs(drum_voices) do
      if drum.pattern[s][v] then
        drum.vels[s][v] = vel_curve(vc,
          v==\"kick\" and 110 or v==\"snare\" and 95 or 80)
      else
        drum.vels[s][v] = 0
      end
    end

    -- ghost notes: very soft hits on quiet steps
    for _,v in ipairs({"snare","hat_c","perc1"}) do
      if not drum.pattern[s][v] and math.random() < drum.ghost_prob then
        drum.ghost[s][v]  = true
        drum.ghost_v[s][v]= math.random(20, 45)
      else
        drum.ghost[s][v] = false
      end
    end
  end
end

-- ============================================================
-- SYNTH ENGINE
-- ============================================================
-- Phrases: the synth generates in 4-step "phrases" that
-- respect the current chord of the progression, then move
-- to the next chord. This creates harmonic movement even
-- within a single 16-step loop.
--
-- Motif memory: a short motif is occasionally repeated
-- (transposed to the new chord root) for coherence.
-- "wrong" notes: 5% chance of a passing tone 1 semitone
-- outside the scale — human-sounding accidents.

local synth = {
  root  = 60,
  scale = "minor",
  steps = 16,
  density = 0.55,
  octave_range = 1,
  gate  = 0.45,
  vel_base = 90,
  vel_rand = 20,

  -- per-step data
  pattern = {},
  notes   = {},
  vels    = {},
  lengths = {},

  -- phrase system (4 steps per chord, 4 chords = 16 steps)
  phrase_len  = 4,
  progression = {},     -- list of chord root notes for current prog
  chord_tones = {},     -- [step] = list of available chord tones

  -- motif memory
  motif       = {},     -- up to 4 notes captured
  motif_len   = 0,
  use_motif_prob = 0.25,

  -- passing tone probability (happy accident)
  passing_prob = 0.06,

  -- rest probability (space is musical)
  rest_prob    = 0.3,

  -- contour: the shape of the melody phrase
  -- "arch"=goes up then down, "fall"=descends, "rise"=ascends,
  -- "static"=stays near root, "random"=free
  contour = "arch",
  contour_names = {"arch","fall","rise","static","random","zigzag"},

  -- register: which octave range melodic notes prefer
  register = 0,  -- 0=low, 1=mid, 2=high

  auto_mutate = false,
  mutate_interval = 8,
  mutate_count = 0,
  seq_scale    = nil,
  seq_density  = nil,
  seq_contour  = nil,
}

local function scale_note(root, sname, degree, oct_off)
  local sc = SCALES[sname] or SCALES["minor"]
  local idx = ((degree-1) % #sc) + 1
  local oct = math.floor((degree-1) / #sc)
  return root + sc[idx] + (oct + (oct_off or 0)) * 12
end

local function nearest_scale_note(root, sname, midi_note)
  -- find closest scale tone to a given MIDI note
  local sc = SCALES[sname] or SCALES["minor"]
  local best, best_dist = midi_note, 999
  for oct = -1, 2 do
    for _, iv in ipairs(sc) do
      local n = root + iv + oct * 12
      local d = math.abs(n - midi_note)
      if d < best_dist then best = n; best_dist = d end
    end
  end
  return best
end

local function chord_tones_for(chord_root, quality, sname)
  local ivs = CHORD_Q[quality] or CHORD_Q["m"]
  local tones = {}
  for oct = 0, 2 do
    for _, iv in ipairs(ivs) do
      table.insert(tones, chord_root + iv + oct * 12)
    end
  end
  return tones
end

-- Apply contour: returns an octave offset tendency for step s in phrase
local function contour_oct(contour_name, phrase_step, phrase_len)
  local p = (phrase_step - 1) / math.max(phrase_len - 1, 1) -- 0–1
  if contour_name == "arch" then
    return p < 0.5 and math.floor(p * 2) or math.floor((1 - p) * 2)
  elseif contour_name == "fall" then
    return math.floor((1 - p) * 2)
  elseif contour_name == "rise" then
    return math.floor(p * 2)
  elseif contour_name == "static" then
    return 0
  elseif contour_name == "zigzag" then
    return (phrase_step % 2 == 0) and 1 or 0
  else
    return math.random(0, 1)
  end
end

local function build_progression(prog_name, root, sname)
  local prog = PROGRESSIONS[prog_name] or PROGRESSIONS["verse"]
  local sc   = SCALES[sname] or SCALES["minor"]
  local chords = {}
  for _, cd in ipairs(prog) do
    local deg     = cd[1]
    local quality = cd[2]
    local idx     = ((deg-1) % #sc) + 1
    local chord_root = root + sc[idx]
    table.insert(chords, {root=chord_root, quality=quality})
  end
  return chords
end

local function gen_synth(section)
  section = section or SECTIONS[1]
  local prog_name = section.prog or "verse"
  local vc        = section.velocity_curve
  synth.density   = section.synth_density

  -- build chord progression for this pattern
  local chords = build_progression(prog_name, synth.root, synth.scale)

  -- steps per chord
  local spc = math.floor(synth.steps / #chords)

  -- optionally capture a motif from last run
  local captured_motif = {}

  for s = 1, synth.steps do
    local phrase_pos  = (s - 1) % spc + 1           -- 1..spc within chord
    local chord_idx   = math.floor((s-1) / spc) + 1
    chord_idx = math.min(chord_idx, #chords)
    local chord       = chords[chord_idx]
    local tones       = chord_tones_for(chord.root, chord.quality, synth.scale)

    -- base rest probability (more rests at low energy)
    local rest_p = synth.rest_prob * (1 - section.energy * 0.5)
    synth.pattern[s] = math.random() > rest_p and math.random() < synth.density

    if synth.pattern[s] then
      local note

      -- motif replay?
      if synth.motif_len > 0 and math.random() < synth.use_motif_prob then
        -- transpose motif to current chord root
        local motif_i = ((s-1) % synth.motif_len) + 1
        local interval = synth.motif[motif_i] - synth.root
        note = nearest_scale_note(chord.root, synth.scale,
          chord.root + interval)
      else
        -- pick from chord tones, shaped by contour
        local ct_oct = contour_oct(synth.contour, phrase_pos, spc) + synth.register
        -- filter tones to preferred register
        local preferred = {}
        for _, t in ipairs(tones) do
          local rel = t - chord.root
          if rel >= ct_oct * 12 and rel < (ct_oct + 1) * 12 + 7 then
            table.insert(preferred, t)
          end
        end
        if #preferred == 0 then preferred = tones end
        note = preferred[math.random(1, #preferred)]

        -- passing tone: occasional chromatic neighbour
        if math.random() < synth.passing_prob then
          local direction = math.random() < 0.5 and 1 or -1
          note = note + direction  -- 1 semitone outside scale
        end
      end

      -- clamp to reasonable range
      note = util.clamp(note, synth.root - 12, synth.root + 36)
      synth.notes[s] = note

      -- length: longer notes on chord tones, shorter on passing
      local is_chord_tone = false
      for _, t in ipairs(tones) do
        if t == note then is_chord_tone = true; break end
      end
      local base_gate = synth.gate * (is_chord_tone and 1.2 or 0.7)
      -- occasional long held note for breathiness
      if math.random() < 0.1 then base_gate = base_gate * 2.5 end
      synth.lengths[s] = base_gate

      synth.vels[s] = vel_curve(vc, synth.vel_base, synth.vel_rand)

      -- Record pattern if capture mode active
      capture_synth_event(s, note)

      -- capture for motif
      if #captured_motif < 4 then table.insert(captured_motif, note) end
    end
  end

  -- update motif memory probabilistically
  if #captured_motif > 0 and math.random() < 0.4 then
    synth.motif     = captured_motif
    synth.motif_len = #captured_motif
  end
end

-- ============================================================
-- ARP ENGINE (simplified, runs alongside synth)
-- ============================================================
local CHORD_TYPES = {
  minor={0,3,7}, major={0,4,7}, sus2={0,2,7}, sus4={0,5,7},
  min7={0,3,7,10}, maj7={0,4,7,11}, dom7={0,4,7,10},
  power={0,7}, dim={0,3,6},
}
local chord_type_names = {"minor","major","sus2","sus4","min7","maj7","dom7","power","dim"}

local ARP_PATTERNS = {
  up={1,2,3,4}, down={4,3,2,1}, updown={1,2,3,4,3,2},
  bounce={1,3,2,4}, skip={1,3,1,4}, cascade={1,2,3,2,3,4},
  trill={1,2,1,3,1,4},
}
local arp_names = {"up","down","updown","bounce","skip","cascade","trill","random"}

local arp = {
  root=48, chord_type="minor", pattern_name="up",
  speed=1, octaves=2, chord_notes={}, step=1, running=false,
  vel_base=82, vel_rand=20, gate=0.45,
  seq_pattern=nil, seq_chord=nil, auto_mutate=false,
}

local function build_arp_()
  local ivs = CHORD_TYPES[arp.chord_type] or CHORD_TYPES["minor"]
  arp.chord_notes = {}
  for oct=0,arp.octaves-1 do
    for _,iv in ipairs(ivs) do table.insert(arp.chord_notes,arp.root+iv+oct*12) end
  end
  arp.step=1
end

local function arp_note(step_idx)
  if #arp.chord_notes==0 then return arp.root end
  if arp.pattern_name=="random" then
    return arp.chord_notes[math.random(1,#arp.chord_notes)]
  end
  local pat = ARP_PATTERNS[arp.pattern_name] or ARP_PATTERNS["up"]
  local n   = #arp.chord_notes
  return arp.chord_notes[((pat[((step_idx-1)%#pat)+1]-1)%n)+1]
end

-- ============================================================
-- SECTION MANAGEMENT
-- ============================================================
local section_state = {
  current = 1,
  bar_count = 0,
  transition_pending = false,
  auto = false,
  -- display
  name = "verse",
  energy = 0.4,
}

local function apply_section(idx)
  local sec = SECTIONS[idx]
  section_state.current = idx
  section_state.bar_count = 0
  section_state.name   = sec.name
  section_state.energy = sec.energy
  gen_drums(sec)
  gen_synth(sec)
end

local function next_section()
  local idx = section_seq()
  apply_section(idx)
  return SECTIONS[idx].name
end

-- ============================================================
-- LFO ENGINE (same as v2, condensed)
-- ============================================================
local function shape_sine(ph)   return 0.5+0.5*math.sin(ph*math.pi*2) end
local function shape_tri(ph)    return ph<0.5 and ph*2 or 2-ph*2 end
local function shape_saw_u(ph)  return ph end
local function shape_saw_d(ph)  return 1-ph end
local function shape_sq(ph)     return ph<0.5 and 1 or 0 end
local function shape_sqs(ph)
  local s=0.05; if ph<s then return ph/s elseif ph<0.5-s then return 1
  elseif ph<0.5+s then return 1-((ph-(0.5-s))/(s*2)) else return 0 end
end
local function shape_steps(ph) math.randomseed(math.floor(ph*8)*997); return math.random() end
local SHAPE_NAMES = {"sine","tri","saw↑","saw↓","sq","s.sq","steps","S&H"}
local SHAPE_FNS   = {shape_sine,shape_tri,shape_saw_u,shape_saw_d,shape_sq,shape_sqs,shape_steps,nil}

local lfo = {}
for i=1,4 do
  lfo[i]={on=false,shape=1,sync=true,sync_div=4,phase=0,depth=40,centre=64,
          polarity=1,env_shape=1,sh_val={0.5},last_cc=64,euclid_on=false,
          euclid_k=4,euclid_n=8,euclid_pat=gen_euclid(4,8)}
end

local function lfo_env_amp(e,ph)
  if e==1 then return 1 elseif e==2 then return ph elseif e==3 then return 1-ph
  elseif e==4 then return math.sin(ph*math.pi) else return 1-math.sin(ph*math.pi) end
end

local function tick_lfo(i, dt)
  local l=lfo[i]; if not l.on then return l.last_cc end
  local rate_hz = l.sync and (1/clock.get_beat_sec()/l.sync_div) or l.rate
  local prev=l.phase; l.phase=(l.phase+rate_hz*dt)%1
  if l.shape==8 and l.phase<prev then l.sh_val[1]=math.random() end
  local raw=(SHAPE_FNS[l.shape] or function() return l.sh_val[1] end)(l.phase)
  raw=raw*lfo_env_amp(l.env_shape,l.phase)
  if l.euclid_on and #l.euclid_pat>0 then
    if not l.euclid_pat[math.floor(l.phase*#l.euclid_pat)+1] then raw=0.5 end
  end
  local cv = l.polarity==1 and (l.centre+(raw-0.5)*2*l.depth) or (l.centre+raw*l.depth)
  l.last_cc=math.floor(util.clamp(cv,0,127))
  return l.last_cc
end

-- ============================================================
-- ANIMATION
-- ============================================================
local anim = {
  msg="",msg_timer=0,msg_ttl=1.8,
  note_flash=0,drum_flash=0,lfo_flash={0,0,0,0},
  page_anim=1,play_pulse=0,enc_spark={0,0,0},
  arp_history={},arp_hist_max=32,drum_last={},
  -- section transition flash
  section_flash=0,
  -- drum hit sparks per voice (for drum viz)
  drum_sparks={},
  -- synth note history for phrase viz
  phrase_history={},  -- ring of {note, chord_idx, step}
}
local DECAY=0.10
local redraw_metro

local function toast(msg) anim.msg=msg; anim.msg_timer=anim.msg_ttl end

-- ============================================================
-- STATE
-- ============================================================
local m
local playing  = false
local page     = 1
local alt      = false
local step_vis = 1
local pages     = {"DRUM","SYNTH","LFO","PERFORM"}
local page_icon = {"◈","~","∿","✦"}
local lfo_focus = 1

local glob = {
  tempo_bpm=120, clock_send=true,
  mute_drum=false, mute_synth=false, mute_arp=false,
  vel_follow=false,
}

-- current section (mirrored for display)
local cur_section = SECTIONS[1]

-- ============================================================
-- HELPERS
-- ============================================================
local function send_note_on(note,vel)
  if m then m:note_on(note,math.floor(util.clamp(vel,1,127)),OP1_CH) end
end
local function send_note_off(note)
  if m then m:note_off(note,0,OP1_CH) end
end
local function send_cc(slot,val)
  if m then m:cc(CC[slot],math.floor(util.clamp(val,0,127)),OP1_CH) end
  anim.lfo_flash[slot]=math.max(anim.lfo_flash[slot],0.3)
end
local function rrand(lo,hi) return lo+math.floor(math.random()*(hi-lo+1)) end

-- ============================================================
-- SEQUINS
-- ============================================================
local function init_sequins()
  synth.seq_scale   = sequins({"minor","dorian","pentatonic","minor","phrygian","blues"})
  synth.seq_density = sequins({0.4,0.65,0.5,0.7,0.35,0.6})
  synth.seq_contour = sequins({"arch","fall","rise","zigzag","static","random"})
  drum.seq_density  = sequins({0.4,0.65,0.5,0.75,0.45,0.7})
  arp.seq_pattern   = sequins({"up","bounce","skip","cascade","trill","random"})
  arp.seq_chord     = sequins({"minor","sus2","min7","dom7","power","maj7"})
end

-- ============================================================
-- LATTICE
-- ============================================================
local the_lattice
local patt_drum,patt_synth,patt_arp,patt_lfo,patt_section

local function drum_hit(note, vel, len, timing_nudge)
  local nudge = timing_nudge or 0
  clock.run(function()
    if nudge > 0 then clock.sleep(nudge) end
    send_note_on(note, vel)
    clock.sleep(clock.get_beat_sec() * (len or 0.15))
    send_note_off(note)
  end)
end

local function build_lattice()
  if the_lattice then the_lattice:destroy() end
  the_lattice=lattice:new{auto=true,meter=4,ppqn=96}

  -- DRUM: 16th notes with micro-timing, ghost notes, fills
  local ds=0
  patt_drum=the_lattice:new_pattern{
    division=1/4, enabled=true,
    action=function(t)
      ds=(ds%drum.steps)+1; step_vis=ds
      anim.drum_last={}

      -- check for fill trigger (every 4 beats = 1 bar)
      local is_bar_end = (ds >= drum.fill_step)
      if ds == 1 then
        drum.fill_active = math.random() < drum.fill_prob
        if drum.fill_active then
          drum.fill = gen_drum_fill(cur_section)
        end
      end

      if not glob.mute_drum then
        local p  = drum.pattern[ds]
        local v  = drum.vels[ds]
        local gp = drum.ghost[ds]
        local gv = drum.ghost_v[ds]
        local fp = drum.fill_active and drum.fill[ds]

        for _,voice in ipairs(drum_voices) do
          local note = drum_voice_notes[voice]
          if not note then goto continue end
          local hit_vel = 0
          local use_fill = fp and fp[voice]
          if use_fill and is_bar_end then
            hit_vel = vel_curve(drum.velocity_curve, 90)
          elseif p and p[voice] and v and v[voice] and v[voice]>0 then
            hit_vel = v[voice]
          elseif gp and gp[voice] and gv and gv[voice] then
            hit_vel = gv[voice]  -- ghost: very soft
          end
          if hit_vel > 0 then
            local nudge = 0
            -- swing on even 16ths
            if drum.swing_amt > 0 and ds % 2 == 0 then
              nudge = clock.get_beat_sec() * drum.swing_amt
            end
            -- micro-timing humanisation
            nudge = nudge + micro_timing(section_state.energy) * clock.get_beat_sec()
            drum_hit(note, hit_vel, 0.12, math.max(0, nudge))
            anim.drum_last[voice]=true
            anim.drum_flash=1.0
            -- Record drum events if in capture mode
            if record_mode_active and drum.pattern[ds][voice] then
              capture_drum_event(ds, drum.pattern[ds])
            end
          end
          ::continue::
        end
      end

      anim.play_pulse=1.0
    end
  }

  -- SYNTH: 16th notes, phrase-aware, with passing tones
  local ss=0
  patt_synth=the_lattice:new_pattern{
    division=1/4, enabled=true,
    action=function(t)
      ss=(ss%synth.steps)+1
      if not glob.mute_synth and synth.pattern[ss] then
        local n=synth.notes[ss]; local vel=synth.vels[ss]
        local len=synth.lengths[ss]
        -- tiny velocity humanisation
        vel = util.clamp(vel + math.random(-5,5), 1, 127)
        send_note_on(n,vel)
        if glob.vel_follow then send_cc(4,vel) end
        anim.note_flash=1.0
        -- track for phrase visualisation
        table.insert(anim.phrase_history,
          {note=n,step=ss,chord=math.floor((ss-1)/4)+1})
        if #anim.phrase_history > 64 then table.remove(anim.phrase_history,1) end
        clock.run(function()
          clock.sleep(clock.get_beat_sec()*len); send_note_off(n)
        end)
      end
    end
  }

  -- ARP
  patt_arp=the_lattice:new_pattern{
    division=1/4,enabled=true,
    action=function(t)
      if glob.mute_arp or not arp.running then return end
      local n=arp_note(arp.step)
      local vel=util.clamp(arp.vel_base+rrand(-arp.vel_rand,arp.vel_rand),1,127)
      send_note_on(n,vel)
      table.insert(anim.arp_history,n)
      if #anim.arp_history>anim.arp_hist_max then table.remove(anim.arp_history,1) end
      anim.note_flash=1.0
      clock.run(function()
        clock.sleep(clock.get_beat_sec()*arp.gate); send_note_off(n)
      end)
      arp.step=arp.step+1
    end
  }

  -- LFO
  patt_lfo=the_lattice:new_pattern{
    division=1/16, enabled=true,
    action=function(t)
      local dt=clock.get_beat_sec()/4
      for i=1,4 do if lfo[i].on then send_cc(i,tick_lfo(i,dt)) end end
    end
  }

  -- SECTION: checks every bar whether to auto-advance
  patt_section=the_lattice:new_pattern{
    division=4, enabled=true,
    action=function(t)
      local sec=SECTIONS[section_state.current]
      section_state.bar_count=section_state.bar_count+1

      -- auto-mutate drum
      if drum.auto_mutate then
        drum.mutate_count=drum.mutate_count+1
        if drum.mutate_count>=drum.mutate_interval then
          drum.mutate_count=0
          drum.density=drum.seq_density()
          gen_drums(cur_section); toast("drums shifted")
        end
      end

      -- auto-mutate synth
      if synth.auto_mutate then
        synth.mutate_count=synth.mutate_count+1
        if synth.mutate_count>=synth.mutate_interval then
          synth.mutate_count=0
          synth.scale=synth.seq_scale()
          synth.contour=synth.seq_contour()
          gen_synth(cur_section); toast("phrase → "..synth.contour)
        end
      end

      -- auto section advance
      if section_state.auto and sec.auto_advance then
        if section_state.bar_count >= sec.bars then
          local sname=next_section()
          cur_section=SECTIONS[section_state.current]
          anim.section_flash=1.0
          toast("→ "..sname)
        end
      end
    end
  }

  -- MIDI clock
  if glob.clock_send then
    clock.run(function()
      while playing do
        if m then m:clock() end
        clock.sleep(clock.get_beat_sec()/24)
      end
    end)
  end

  the_lattice:start()
end

local function stop_all()
  if the_lattice then the_lattice:destroy(); the_lattice=nil end
  if m then
    m:stop()
    for i=0,127 do m:note_off(i,0,OP1_CH) end
    m:cc(123,0,OP1_CH)
    for i=1,4 do m:cc(CC[i],lfo[i].centre,OP1_CH) end
  end
  step_vis=1
end

-- ============================================================
-- INIT
-- ============================================================
function init()
  math.randomseed(os.time())
  m=midi.connect(MIDI_DEV)
  init_midi_handler()

  params:add_separator("FIELDBOT")
  params:add_number("midi_dev","MIDI device",1,4,1)
  params:set_action("midi_dev",function(v) MIDI_DEV=v; m=midi.connect(v); init_midi_handler() end)
  params:add_number("op1_ch","OP-1 channel",1,16,1)
  params:set_action("op1_ch",function(v) OP1_CH=v end)
  params:add_option("scale","Scale",scale_names,1)
  params:set_action("scale",function(v)
    synth.scale=scale_names[v]; arp.root=synth.root-12
    gen_synth(cur_section); toast("scale → "..scale_names[v])
  end)
  params:add_number("root","Root (MIDI)",48,72,60)
  params:set_action("root",function(v)
    synth.root=v; arp.root=v-12; gen_synth(cur_section)
  end)

  for i=1,4 do lfo[i].euclid_pat=gen_euclid(lfo[i].euclid_k,lfo[i].euclid_n) end
  init_sequins()

  apply_section(1)
  cur_section=SECTIONS[1]
  build_arp_()

  redraw_metro=metro.init(function()
    local function d(v) return math.max(0,v-DECAY) end
    anim.note_flash=d(anim.note_flash); anim.drum_flash=d(anim.drum_flash)
    anim.play_pulse=d(anim.play_pulse); anim.section_flash=d(anim.section_flash)
    for i=1,4 do anim.lfo_flash[i]=d(anim.lfo_flash[i]) end
    for i=1,3 do anim.enc_spark[i]=d(anim.enc_spark[i]) end
    anim.page_anim=math.min(1,anim.page_anim+0.14)
    if anim.msg_timer>0 then
      anim.msg_timer=anim.msg_timer-(1/60)
      if anim.msg_timer<=0 then anim.msg="" end
    end
    redraw()
  end,1/60,-1)
  redraw_metro:start()

  anim.page_anim=0
  toast("FIELDBOT v3.1")
  redraw()
end

-- ============================================================
-- CONTROLS
-- ============================================================
function key(id,z)
  if id==1 then alt=(z==1); redraw(); return end
  if z==0 then return end

  if id==2 then
    if alt then
      playing=not playing
      if playing then
        if m then m:start() end
        build_lattice(); toast("▶  "..section_state.name)
      else
        stop_all(); toast("■  stopped")
      end
    else
      if page==1 then
        gen_drums(cur_section); toast("drums regen → "..section_state.name)
      elseif page==2 then
        gen_synth(cur_section); toast("synth regen / "..synth.contour)
      elseif page==3 then
        lfo_focus=(lfo_focus%4)+1; toast("LFO "..lfo_focus.." → "..CC_DEST[lfo_focus])
      elseif page==4 then
        -- randomise all LFOs
        for i=1,4 do lfo[i].shape=rrand(1,#SHAPE_NAMES); lfo[i].depth=rrand(20,55) end
        toast("LFOs randomised")
      end
    end
  end

  if id==3 then
    if alt then
      if m then m:stop(); clock.sleep(0.05); m:start() end
      toast("seq reset")
    else
      if page==1 then
        -- drum: advance section
        local sname=next_section()
        cur_section=SECTIONS[section_state.current]
        anim.section_flash=1.0
        toast("→ "..sname)
      elseif page==2 then
        -- synth: mutate contour + scale
        synth.contour=synth.seq_contour()
        synth.scale=synth.seq_scale()
        gen_synth(cur_section)
        toast(synth.scale.." / "..synth.contour)
      elseif page==3 then
        local l=lfo[lfo_focus]
        l.on=not l.on
        toast("LFO "..lfo_focus..(l.on and " ON" or " off"))
      elseif page==4 then
        section_state.auto=not section_state.auto
        toast("auto-section: "..(section_state.auto and "ON" or "off"))
      end
    end
  end
  redraw()
end

function enc(id,d)
  anim.enc_spark[id]=1.0
  if id==1 then page=util.clamp(page+d,1,#pages); anim.page_anim=0; return end

  if page==1 then  -- DRUM
    if id==2 then
      -- E2: section energy nudge → re-applies density
      section_state.energy=util.clamp(section_state.energy+d*0.05,0,1)
      SECTIONS[section_state.current].energy=section_state.energy
      gen_drums(SECTIONS[section_state.current])
      toast(string.format("energy %.0f%%",section_state.energy*100))
    elseif id==3 then
      drum.swing_amt=util.clamp(drum.swing_amt+d*0.005,0,0.15)
      toast(string.format("swing %.0f%%",drum.swing_amt/0.15*100))
    end

  elseif page==2 then  -- SYNTH
    if id==2 then
      synth.register=util.clamp(synth.register+d,0,2)
      local regs={"low","mid","high"}
      gen_synth(cur_section)
      toast("register: "..regs[synth.register+1])
    elseif id==3 then
      -- cycle contour
      local names=synth.contour_names
      local ci=1
      for i,n in ipairs(names) do if n==synth.contour then ci=i end end
      ci=util.clamp(ci+d,1,#names)
      synth.contour=names[ci]
      gen_synth(cur_section)
      toast("contour: "..synth.contour)
    end

  elseif page==3 then  -- LFO
    local l=lfo[lfo_focus]
    if id==2 then
      l.shape=util.clamp(l.shape+d,1,#SHAPE_NAMES)
      toast("LFO"..lfo_focus.." "..SHAPE_NAMES[l.shape])
    elseif id==3 then
      if alt then
        local divs={0.25,0.5,1,2,4,8,16}
        local dn={"1/16","1/8","1/4","1/2","1b","2b","4b"}
        local ci=1
        for i,v in ipairs(divs) do if math.abs(v-l.sync_div)<0.01 then ci=i end end
        ci=util.clamp(ci+d,1,#divs); l.sync_div=divs[ci]
        toast("LFO"..lfo_focus.." "..dn[ci])
      else
        l.depth=util.clamp(l.depth+d,0,64)
        toast("LFO"..lfo_focus.." depth "..l.depth)
      end
    end

  elseif page==4 then  -- PERFORM
    if id==2 then
      lfo_focus=util.clamp(lfo_focus+d,1,4)
      toast("focus: "..CC_DEST[lfo_focus])
    elseif id==3 then
      local l=lfo[lfo_focus]
      l.centre=util.clamp(l.centre+d,0,127)
      if not l.on then send_cc(lfo_focus,l.centre) end
      toast(CC_DEST[lfo_focus].." centre "..l.centre)
    end
  end
  redraw()
end

-- ============================================================
-- SCREEN
-- ============================================================
local function pill(x,y,w,h,val,mx,bl,fl)
  screen.level(bl or 2); screen.rect(x,y,w,h); screen.stroke()
  local fw=math.max(0,math.floor(w*util.clamp(val/mx,0,1)))
  if fw>0 then screen.level(fl or 10); screen.rect(x,y,fw,h); screen.fill() end
end

-- Energy bar (right side, vertical)
local function draw_energy_bar()
  local e=section_state.energy
  local bh=40; local by=14; local bx=122
  screen.level(2); screen.rect(bx,by,4,bh); screen.stroke()
  local fh=math.floor(bh*e)
  local el=math.floor(4+e*11+anim.section_flash*6)
  screen.level(el); screen.rect(bx,by+bh-fh,4,fh); screen.fill()
end

-- Section name badge
local function draw_section_badge(x,y)
  local flash=anim.section_flash
  screen.level(math.floor(5+flash*10))
  screen.move(x,y); screen.text(section_state.name)
  -- auto indicator
  if section_state.auto then
    screen.level(math.floor(3+flash*8)); screen.move(x+40,y); screen.text("AUTO")
  end
  -- record indicator
  if record_mode_active then
    screen.level(15); screen.move(x+80,y); screen.text("REC")
  end
end

local function draw_drum_page()
  -- Voice rows: kick snare hat clap (always shown)
  -- + ghost note indicator + fill indicator
  local rows  = {"kick","snare","hat_c","clap"}
  local lbls  = {"K","S","H","C"}
  local y_off = 20

  -- section badge top
  draw_section_badge(0,18)
  draw_energy_bar()

  for r,voice in ipairs(rows) do
    local y = y_off + r*9
    local fired = anim.drum_last[voice]

    screen.level(fired and 15 or 4)
    screen.move(0,y); screen.text(lbls[r])

    for s=1,drum.steps do
      local x = 10+(s-1)*7
      local on  = drum.pattern[s] and drum.pattern[s][voice]
      local gh  = drum.ghost[s] and drum.ghost[s][voice]
      local fl  = drum.fill_active and drum.fill[s] and drum.fill[s][voice]
      local cur = (s==step_vis)

      if fl and s >= drum.fill_step then
        -- fill: bright outline
        screen.level(cur and 15 or 12)
        screen.rect(x,y-7,5,6); screen.stroke()
        if cur then screen.rect(x,y-7,5,6); screen.fill() end
      elseif on then
        screen.level(cur and 15 or (fired and r==1 and 14 or 9))
        screen.rect(x,y-7,5,6); screen.fill()
      elseif gh then
        -- ghost: tiny dot
        screen.level(cur and 6 or 3)
        screen.rect(x+1,y-4,3,2); screen.fill()
      else
        screen.level(2); screen.rect(x,y-7,5,6); screen.stroke()
      end
    end
  end

  -- Bottom strip
  screen.level(3); screen.move(0,61); screen.line(121,61); screen.stroke()
  screen.level(5); screen.move(0,63)
  screen.text(string.format("E:%.0f%%  sw:%.0f%%  K3:section",
    section_state.energy*100, drum.swing_amt/0.15*100))
end

local function draw_synth_page()
  -- Piano roll coloured by chord
  -- Each chord gets a distinct brightness band
  local sw = 128/synth.steps

  -- draw chord regions as background shading
  local chords_count = 4
  local steps_per_chord = synth.steps / chords_count
  for ci=1,chords_count do
    local x = math.floor((ci-1)*steps_per_chord*sw)
    local w = math.floor(steps_per_chord*sw)
    screen.level(ci%2==0 and 1 or 0)
    screen.rect(x,11,w,50); screen.fill()
  end

  draw_section_badge(0,18)
  draw_energy_bar()

  -- notes
  local lo_note, hi_note = synth.root-2, synth.root+38
  for s=1,synth.steps do
    local x=(s-1)*sw
    local cur=(s==step_vis)
    if synth.pattern[s] then
      local n=synth.notes[s]
      local nrm=util.clamp((n-lo_note)/(hi_note-lo_note),0,1)
      local h=math.floor(nrm*28+2)
      local chord_idx=math.floor((s-1)/steps_per_chord)+1
      -- chord-tinted brightness
      local base_l = cur and 15 or (playing and (6+chord_idx) or 4)
      screen.level(base_l)
      screen.rect(x+1,58-h,sw-1,h); screen.fill()
      -- top highlight
      screen.level(math.min(15, base_l+2))
      screen.rect(x+1,58-h,sw-1,1); screen.fill()
    else
      screen.level(2); screen.rect(x+1,58,sw-1,1); screen.fill()
    end
  end

  -- step cursor
  if playing then
    local cx=math.floor((step_vis-1)*sw+sw/2)
    screen.level(math.floor(5+anim.play_pulse*10))
    screen.move(cx,60); screen.line(cx,62); screen.stroke()
  end

  screen.level(3); screen.move(0,61); screen.line(121,61); screen.stroke()
  screen.level(5); screen.move(0,63)
  screen.text(synth.contour.."  "..synth.scale:sub(1,4)
    .."  r:"..musicutil.note_num_to_name(synth.root))
end

local function draw_lfo_wave(x,y,w,h,li)
  local l=lfo[li]; local fn=SHAPE_FNS[l.shape]; local ppy=nil
  screen.level(l.on and 2 or 1); screen.rect(x,y,w,h); screen.fill()
  for px=0,w-1 do
    local ph=px/(w-1)
    local raw=fn and fn(ph) or l.sh_val[1]
    raw=raw*lfo_env_amp(l.env_shape,ph)
    if l.polarity==1 then raw=raw else raw=raw*0.5+0.5 end
    local py=math.max(y,math.min(y+h-1,math.floor(y+h-raw*h)))
    screen.level(l.on and (9+math.floor(anim.lfo_flash[li]*6)) or 4)
    if ppy then screen.move(x+px-1,ppy); screen.line(x+px,py); screen.stroke() end
    ppy=py
  end
  if l.on and playing then
    local cx=math.floor(x+l.phase*w)
    screen.level(15); screen.move(cx,y); screen.line(cx,y+h); screen.stroke()
  end
end

local function draw_lfo_page()
  local cols={{0,0},{66,0},{0,26},{66,26}}
  for i=1,4 do
    local cx,cy=cols[i][1],cols[i][2]; local l=lfo[i]; local foc=(i==lfo_focus)
    screen.level(foc and 8 or (l.on and 3 or 1))
    screen.rect(cx,cy+11,62,20); screen.stroke()
    draw_lfo_wave(cx+1,cy+12,60,18,i)
    screen.level(l.on and 15 or 4); screen.move(cx,cy+10); screen.text(CC_DEST[i])
    screen.level(foc and 12 or 5); screen.move(cx+28,cy+10)
    screen.text(SHAPE_NAMES[l.shape])
    if foc then
      screen.level(9); screen.move(cx,cy+32)
      local dn={"1/16","1/8","1/4","1/2","1b","2b","4b"}
      local divs={0.25,0.5,1,2,4,8,16}; local ds="?"
      for di,v in ipairs(divs) do if math.abs(v-l.sync_div)<0.01 then ds=dn[di] end end
      screen.text("d:"..l.depth.."  "..ds)
    end
    screen.level(l.on and 15 or 2); screen.circle(cx+57,cy+10,2)
    if l.on then screen.fill() else screen.stroke() end
  end
  screen.level(3); screen.move(0,63)
  screen.text("E2=shape  E3=depth  K3=on/off")
end

local function draw_perform_page()
  screen.level(5); screen.move(0,18); screen.text("CC → OP-1  section:"..section_state.name)
  for i=1,4 do
    local l=lfo[i]; local y=26+i*9; local fl=anim.lfo_flash[i]
    screen.level(math.floor(4+fl*10)); screen.move(0,y); screen.text(CC_DEST[i])
    pill(28,y-7,80,6,l.last_cc,127,2,math.floor(5+fl*9))
    screen.level(l.on and (math.floor(7+fl*8)) or 2)
    screen.move(112,y); screen.text(l.on and SHAPE_NAMES[l.shape]:sub(1,3) or "off")
    screen.level(8); screen.move(118,y); screen.text(l.last_cc)
  end
  screen.level(3); screen.move(0,63)
  screen.text("E2=lane  E3=centre  K3=auto-sect")
end

function redraw()
  screen.clear(); screen.aa(0); screen.font_size(8)

  -- HEADER
  screen.level(playing and math.floor(6+anim.play_pulse*9) or 3)
  screen.move(0,8); screen.text(playing and "▶" or "■")
  screen.level(math.floor(anim.page_anim*15))
  screen.move(10,8); screen.text(page_icon[page].." "..pages[page])
  screen.level(math.floor(anim.note_flash*13+2)); screen.move(80,8); screen.text("♩")
  screen.level(math.floor(anim.drum_flash*13+2)); screen.move(88,8); screen.text("●")
  -- LFO dots
  for i=1,4 do
    screen.level(lfo[i].on and math.floor(4+anim.lfo_flash[i]*11) or 2)
    screen.move(96+(i-1)*7,8); screen.text("∿")
  end
  -- step
  screen.level(playing and 5 or 2); screen.move(122,8)
  screen.text(string.format("%02d",step_vis))
  screen.level(3); screen.move(0,9); screen.line(128,9); screen.stroke()

  -- TOAST
  if anim.msg~="" and anim.msg_timer>0 then
    local a=math.min(1,anim.msg_timer*2.5)
    local tw=string.len(anim.msg)*5+8
    screen.level(1); screen.rect(64-tw/2,11,tw,9); screen.fill()
    screen.level(math.floor(a*15)); screen.move(65-tw/2,19); screen.text(anim.msg)
  end

  if     page==1 then draw_drum_page()
  elseif page==2 then draw_synth_page()
  elseif page==3 then draw_lfo_page()
  elseif page==4 then draw_perform_page()
  end

  for i=1,3 do
    if anim.enc_spark[i]>0.05 then
      local s=math.floor(anim.enc_spark[i]*3)
      screen.level(math.floor(anim.enc_spark[i]*10))
      screen.rect((i-1)*55+5,60,s,s); screen.fill()
    end
  end

  if alt then screen.level(15); screen.move(118,8); screen.text("[⇧]") end
  screen.update()
end

-- ============================================================
-- CLEANUP
-- ============================================================
function cleanup()
  if redraw_metro then redraw_metro:stop() end
  if the_lattice  then the_lattice:destroy() end
  if m then
    m:stop()
    for i=0,127 do m:note_off(i,0,OP1_CH) end
    m:cc(123,0,OP1_CH)
    for i=1,4 do m:cc(CC[i],64,OP1_CH) end
  end
end
