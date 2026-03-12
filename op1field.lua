-- FIELDBOT v3
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

local CHORDS = {
  major  = {0,4,7},
  minor  = {0,3,7},
  maj7   = {0,4,7,11},
  min7   = {0,3,7,10},
  dom7   = {0,4,7,10},
  sus2   = {0,2,7},
  sus4   = {0,5,7},
}

-- ============================================================
-- STATE MACHINE
-- ============================================================
local state = {
  running      = false,
  page         = 1,
  section      = 1,
  beat         = 0,
  pattern_len  = 16,
  scale_idx    = 1,
  root_note    = 36,

  -- DRUM state
  drum = {
    density      = 0.5,
    swing        = 0.0,
    fill_prob    = 0.3,
    humanize     = 0.1,
    velocity_min = 60,
    velocity_max = 100,
    kick_pattern = {},
    snare_pattern = {},
    hat_pattern = {},
  },

  -- SYNTH state
  synth = {
    density      = 0.4,
    melodic_range = 12,
    grace_prob   = 0.2,
    step_size    = 1,
    note_len     = 0.25,
  },

  -- LFO state
  lfo = {
    target = 1,
    rate   = 2,
    depth  = 0.5,
  },

  -- Sections: verse, chorus, bridge, drop
  sections = {
    {name="verse",  density=0.4, energy=0.5, vel_min=50, vel_max=90},
    {name="chorus", density=0.6, energy=0.8, vel_min=70, vel_max=110},
    {name="bridge", density=0.3, energy=0.3, vel_min=40, vel_max=70},
    {name="drop",   density=0.8, energy=1.0, vel_min=80, vel_max=120},
  },
}

local PAGES = {
  DRUM    = 1,
  SYNTH   = 2,
  LFO     = 3,
  PERFORM = 4,
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function scale_note(degree, octave)
  local scale = SCALES["minor"]
  local note = scale[(degree % #scale) + 1] + (octave * 12)
  return note + state.root_note
end

local function choose(t)
  return t[math.random(#t)]
end

local function weighted_choice(weight)
  return math.random() < weight
end

local function humanize_note(note, amount)
  return note + math.random(-amount, amount)
end

local function next_section()
  state.section = (state.section % #state.sections) + 1
end

local function beat_pos()
  return (state.beat % state.pattern_len) + 1
end

-- ============================================================
-- DRUM GENERATION
-- ============================================================

local function generate_drum_fill()
  local drum_state = state.drum
  local section = state.sections[state.section]
  local intensity = section.density

  -- Kick pattern: euclidean-ish
  local kick_hits = math.floor(4 * intensity)
  local kick_pattern = {}
  for i = 1, state.pattern_len do
    kick_pattern[i] = (i % math.ceil(state.pattern_len / (kick_hits + 1))) == 0
  end

  -- Snare: alternating with ghost notes
  local snare_pattern = {}
  for i = 1, state.pattern_len do
    if i % 4 == 2 or i % 4 == 0 then
      snare_pattern[i] = true
    elseif weighted_choice(drum_state.fill_prob) then
      snare_pattern[i] = "ghost"
    end
  end

  -- Hat: fast hi-hats
  local hat_pattern = {}
  for i = 1, state.pattern_len * 2 do
    if weighted_choice(intensity * 0.6) then
      hat_pattern[i] = weighted_choice(0.5) and "open" or "closed"
    end
  end

  state.drum.kick_pattern = kick_pattern
  state.drum.snare_pattern = snare_pattern
  state.drum.hat_pattern = hat_pattern
end

local function play_drum_note(note_type, velocity)
  if note_type == "ghost" then
    velocity = math.floor(velocity * 0.4)
  end

  local note_num = DN[note_type] or DN.kick
  if midi then
    midi:note_on(note_num, velocity, OP1_CH)
    -- Quick note off
    clock.sleep(0.05)
    midi:note_off(note_num, OP1_CH)
  end
end

-- ============================================================
-- SYNTH GENERATION
-- ============================================================

local function generate_synth_phrase()
  local synth_state = state.synth
  local section = state.sections[state.section]
  local phrase = {}

  -- Generate melodic contour
  local num_notes = math.random(4, 8)
  local direction = math.random() < 0.5 and 1 or -1
  local current_degree = math.random(0, 6)

  for i = 1, num_notes do
    local note = scale_note(current_degree, 2)
    note = humanize_note(note, 1)

    table.insert(phrase, {
      note = note,
      velocity = math.random(section.vel_min, section.vel_max),
      duration = synth_state.note_len,
    })

    -- Move to next degree with some continuity
    current_degree = current_degree + (direction * synth_state.step_size)
    if current_degree < 0 then
      current_degree = current_degree + 7
      direction = 1
    elseif current_degree > 6 then
      current_degree = current_degree - 7
      direction = -1
    end

    -- Occasional grace notes
    if weighted_choice(synth_state.grace_prob) then
      table.insert(phrase, {
        note = note - 1,
        velocity = 60,
        duration = 0.1,
      })
    end
  end

  return phrase
end

local function play_synth_phrase(phrase)
  if not midi then return end

  for i, note_data in ipairs(phrase) do
    midi:note_on(note_data.note, note_data.velocity, OP1_CH)
    clock.sleep(note_data.duration)
    midi:note_off(note_data.note, OP1_CH)
  end
end

-- ============================================================
-- SEQUENCER LOOP
-- ============================================================

local function drum_clock(beat)
  if not state.running then return end

  state.beat = beat
  local pos = beat_pos()

  -- Check drum patterns
  if state.drum.kick_pattern[pos] then
    local vel = math.random(state.drum.velocity_min, state.drum.velocity_max)
    play_drum_note("kick", vel)
  end

  if state.drum.snare_pattern[pos] then
    local snare_type = state.drum.snare_pattern[pos]
    local vel = math.random(state.drum.velocity_min, state.drum.velocity_max)
    play_drum_note("snare", vel)
  end

  -- Hi-hats (double speed)
  local hat_pos = (beat * 2) % #state.drum.hat_pattern
  if state.drum.hat_pattern[hat_pos] then
    local hat_type = state.drum.hat_pattern[hat_pos]
    local hat_note = hat_type == "open" and "hat_o" or "hat_c"
    play_drum_note(hat_note, 60)
  end

  -- Section advance every 16 beats
  if beat % (state.pattern_len * 4) == 0 then
    next_section()
  end
end

-- ============================================================
-- SCREEN & UI
-- ============================================================

local function redraw_drum_page()
  screen.clear()
  screen.move(0, 8)
  screen.text("DRUM :: " .. state.sections[state.section].name)

  screen.move(0, 20)
  screen.text("density: " .. string.format("%.1f", state.drum.density))
  screen.move(0, 28)
  screen.text("fill: " .. string.format("%.1f", state.drum.fill_prob))
  screen.move(0, 36)
  screen.text("humanize: " .. string.format("%.2f", state.drum.humanize))
  screen.move(0, 44)
  screen.text("running: " .. (state.running and "YES" or "NO"))

  screen.update()
end

local function redraw_synth_page()
  screen.clear()
  screen.move(0, 8)
  screen.text("SYNTH :: " .. state.sections[state.section].name)

  screen.move(0, 20)
  screen.text("density: " .. string.format("%.1f", state.synth.density))
  screen.move(0, 28)
  screen.text("range: " .. state.synth.melodic_range)
  screen.move(0, 36)
  screen.text("grace: " .. string.format("%.1f", state.synth.grace_prob))

  screen.update()
end

local function redraw_lfo_page()
  screen.clear()
  screen.move(0, 8)
  screen.text("LFO")

  screen.move(0, 20)
  screen.text("target: " .. state.lfo.target)
  screen.move(0, 28)
  screen.text("rate: " .. string.format("%.2f", state.lfo.rate))
  screen.move(0, 36)
  screen.text("depth: " .. string.format("%.1f", state.lfo.depth))

  screen.update()
end

local function redraw_perform_page()
  screen.clear()
  screen.move(0, 8)
  screen.text("PERFORM")

  screen.move(0, 20)
  screen.text("beat: " .. state.beat)
  screen.move(0, 28)
  screen.text("section: " .. state.sections[state.section].name)
  screen.move(0, 36)
  screen.text("tempo: " .. clock.tempo)

  screen.update()
end

local function redraw()
  if state.page == PAGES.DRUM then
    redraw_drum_page()
  elseif state.page == PAGES.SYNTH then
    redraw_synth_page()
  elseif state.page == PAGES.LFO then
    redraw_lfo_page()
  else
    redraw_perform_page()
  end
end

-- ============================================================
-- ENCODERS & KEYS
-- ============================================================

function enc(n, d)
  if n == 1 then
    state.page = ((state.page - 1 + d) % 4) + 1
  elseif state.page == PAGES.DRUM then
    if n == 2 then
      state.drum.density = util.clamp(state.drum.density + 0.05 * d, 0, 1)
    elseif n == 3 then
      state.drum.fill_prob = util.clamp(state.drum.fill_prob + 0.05 * d, 0, 1)
    end
  elseif state.page == PAGES.SYNTH then
    if n == 2 then
      state.synth.density = util.clamp(state.synth.density + 0.05 * d, 0, 1)
    elseif n == 3 then
      state.synth.melodic_range = util.clamp(state.synth.melodic_range + d, 6, 24)
    end
  elseif state.page == PAGES.LFO then
    if n == 2 then
      state.lfo.rate = util.clamp(state.lfo.rate + 0.1 * d, 0.1, 8)
    elseif n == 3 then
      state.lfo.depth = util.clamp(state.lfo.depth + 0.05 * d, 0, 1)
    end
  end
  redraw()
end

function key(n, z)
  if n == 1 then
    -- K1: modifier key (held)
    return
  elseif n == 2 then
    if z == 1 then
      -- K2: generate / play
      if state.page == PAGES.DRUM then
        generate_drum_fill()
      elseif state.page == PAGES.SYNTH then
        local phrase = generate_synth_phrase()
        play_synth_phrase(phrase)
      end
    end
  elseif n == 3 then
    if z == 1 then
      -- K3: mutate / next section
      next_section()
      generate_drum_fill()
    end
  end
  redraw()
end

-- ============================================================
-- INIT
-- ============================================================

function init()
  -- Load MIDI device
  midi = midi.connect(MIDI_DEV)

  -- Initialize patterns
  generate_drum_fill()

  -- Setup lattice for clock
  local lat = lattice:new({
    tempo = 120,
  })

  local drum_pattern = lat:pattern({
    action = drum_clock,
    division = 1,
  })

  lat:start()

  -- Start screen redraw loop
  redraw()
end

function cleanup()
  if midi then
    -- All notes off
    for i=1,4 do m:cc(CC[i],64,OP1_CH) end
  end
end

-- ============================================================
-- PERFORMANCE STATE TRACKING
-- ============================================================

local performance_data = {
  last_section_change = 0,
  section_hold_beats = 64,
  synth_phrase_queue = {},
  midi_queue = {},
}

-- ============================================================
-- EXTENDED DRUM PATTERNS
-- ============================================================

local function generate_polyrhythm_pattern()
  local patterns = {
    {2, 3},     -- 2-3 polyrhythm
    {3, 4},     -- 3-4 polyrhythm
    {4, 5},     -- 4-5 polyrhythm
  }
  local chosen = choose(patterns)
  return chosen
end

local function apply_swing(pattern, swing_amount)
  -- Apply swing to every other note
  for i = 2, #pattern, 2 do
    if pattern[i] then
      pattern[i] = pattern[i] + swing_amount
    end
  end
  return pattern
end

local function euclidean_pattern(steps, hits)
  -- Generate euclidean rhythm
  local pattern = {}
  local pattern_array = {}
  
  for i = 1, steps do
    pattern_array[i] = 0
  end
  
  for i = 1, hits do
    pattern_array[math.floor((i - 1) * steps / hits) + 1] = 1
  end
  
  for i = 1, steps do
    pattern[i] = pattern_array[i] == 1
  end
  
  return pattern
end

-- ============================================================
-- ADVANCED SYNTH GENERATION
-- ============================================================

local function generate_arpeggio_pattern(chord_type, octaves)
  local chord = CHORDS[chord_type] or CHORDS.major
  local pattern = {}
  
  for octave = 1, octaves do
    for _, interval in ipairs(chord) do
      table.insert(pattern, scale_note(interval, octave))
    end
  end
  
  return pattern
end

local function apply_scale_quantization(note)
  local scale = SCALES["minor"]
  local octave = math.floor(note / 12)
  local note_in_octave = note % 12
  
  local closest_scale_degree = 0
  local min_distance = 12
  
  for i, degree in ipairs(scale) do
    local distance = math.abs(note_in_octave - degree)
    if distance < min_distance then
      min_distance = distance
      closest_scale_degree = degree
    end
  end
  
  return (octave * 12) + closest_scale_degree
end

-- ============================================================
-- ADVANCED MIDI CONTROL
-- ============================================================

local function send_cc(cc_num, value, channel)
  if midi then
    midi:cc(cc_num, value, channel or OP1_CH)
  end
end

local function modulate_parameter(param_index, lfo_value)
  local cc = CC[param_index]
  local value = math.floor(64 + (lfo_value * 63))
  send_cc(cc, value)
end

-- ============================================================
-- LFO MODULATION
-- ============================================================

local lfo_phases = {0, 0, 0, 0}
local lfo_targets = {
  {"drum", "velocity_min"},
  {"drum", "velocity_max"},
  {"synth", "density"},
  {"lfo", "depth"}
}

local function update_lfo()
  for i = 1, 4 do
    lfo_phases[i] = (lfo_phases[i] + state.lfo.rate) % (2 * math.pi)
    local lfo_value = math.sin(lfo_phases[i])
    modulate_parameter(i, lfo_value)
  end
end

-- ============================================================
-- SECTION-AWARE PATTERN GENERATION
-- ============================================================

local function generate_section_aware_pattern()
  local section = state.sections[state.section]
  
  local drum_state = state.drum
  drum_state.density = section.density
  drum_state.velocity_min = section.vel_min
  drum_state.velocity_max = section.vel_max
  
  generate_drum_fill()
end

-- ============================================================
-- PROBABILITY-BASED MUTATIONS
-- ============================================================

local function mutate_drum_pattern()
  local drum_state = state.drum
  
  -- Randomly mutate density
  if weighted_choice(0.3) then
    drum_state.density = util.clamp(drum_state.density + math.random(-10, 10) / 100, 0, 1)
  end
  
  -- Randomly mutate fill probability
  if weighted_choice(0.3) then
    drum_state.fill_prob = util.clamp(drum_state.fill_prob + math.random(-10, 10) / 100, 0, 1)
  end
  
  -- Randomly mutate humanization
  if weighted_choice(0.3) then
    drum_state.humanize = util.clamp(drum_state.humanize + math.random(-5, 5) / 100, 0, 0.2)
  end
  
  generate_drum_fill()
end

local function mutate_synth_pattern()
  local synth_state = state.synth
  
  -- Randomly mutate density
  if weighted_choice(0.3) then
    synth_state.density = util.clamp(synth_state.density + math.random(-10, 10) / 100, 0, 1)
  end
  
  -- Randomly mutate melodic range
  if weighted_choice(0.3) then
    synth_state.melodic_range = util.clamp(synth_state.melodic_range + math.random(-2, 2), 6, 24)
  end
  
  -- Randomly mutate grace probability
  if weighted_choice(0.3) then
    synth_state.grace_prob = util.clamp(synth_state.grace_prob + math.random(-10, 10) / 100, 0, 0.5)
  end
end

-- ============================================================
-- ARPEGGIATOR SUBSYSTEM
-- ============================================================

local arpeggiator = {
  enabled = false,
  pattern = {},
  position = 1,
  speed = 2,
}

local function update_arpeggiator()
  if not arpeggiator.enabled or #arpeggiator.pattern == 0 then
    return
  end
  
  local note = arpeggiator.pattern[arpeggiator.position]
  if midi then
    midi:note_on(note, 80, OP1_CH)
    clock.sleep(0.25 / arpeggiator.speed)
    midi:note_off(note, OP1_CH)
  end
  
  arpeggiator.position = (arpeggiator.position % #arpeggiator.pattern) + 1
end

-- ============================================================
-- SEQUENCER EVENT QUEUE
-- ============================================================

local event_queue = {}

local function queue_event(event_type, data, delay)
  table.insert(event_queue, {
    type = event_type,
    data = data,
    delay = delay or 0,
    time = clock.get_beat_sec() + delay
  })
end

local function process_event_queue()
  local current_time = clock.get_beat_sec()
  
  for i = #event_queue, 1, -1 do
    if current_time >= event_queue[i].time then
      local event = table.remove(event_queue, i)
      
      if event.type == "note" then
        if midi then
          midi:note_on(event.data.note, event.data.velocity, OP1_CH)
          clock.sleep(event.data.duration)
          midi:note_off(event.data.note, OP1_CH)
        end
      elseif event.type == "cc" then
        send_cc(event.data.cc, event.data.value)
      end
    end
  end
end

-- ============================================================
-- RANDOM ACCENT GENERATION
-- ============================================================

local function generate_accent_map()
  local accents = {}
  for i = 1, state.pattern_len do
    accents[i] = weighted_choice(0.2)
  end
  return accents
end

local accent_map = generate_accent_map()

local function apply_accent(velocity, is_accented)
  if is_accented then
    return math.min(velocity + 20, 127)
  else
    return velocity - 10
  end
end

return state