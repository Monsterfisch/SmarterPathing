--[[
  Smarter Pathing

  1. Assassins carry on to where they were sent after a fight (assassinsResume).
     An assassin may climb walls only while PathFindingState.allAssassinsUnk is set for its
     route search, and the game sets it only where an order is given (the tribe move and
     attack orders, for a group made of assassins alone). Every later search for the same
     order runs without it: resumeMovementAfterInterruption after a fight, and
     processUnitMove's new search when the way is blocked. Those searches go to the order's
     final destination (unit +0xEC/+0xEE), so for a target up on a wall they fail and the
     assassin stops where the fight ended. Other units never need the flag, which is why
     only assassins forget.
     setDestinationForUnit is hooked where it stores that final destination: an assassin's
     order remembers whether it was given with the flag, and a search for the same
     destination again gets the flag back.
     What the assassins remember is kept in saved games through map-extensions (the unit ids
     that may climb), and wiped for a game started from a map.

  2. Assassins only climb when it is clearly shorter (assassinsShortcut). The climbing search
     (pathFindingWithBuildingsIncluded) does not care how often a route goes up and down
     walls. setDestinationForUnit's route search gets a policy through the route-search
     module: a search that may climb first runs without the climb flag, and a ground route
     is kept when it is short, or when the climbing route is not shorter by at least
     shortcutSavingPercent. Gatehouse Fixes' gate rules (another policy) run inside each
     of those searches, for the same unit.

  3. Aggressive troops leave quarry stockpiles alone (ignoreQuarryPiles). The aggressive
     stance's building search skips the stockpile through a per-type table but not the
     quarry stockpile; its entry is cleared too.

  4. Workers on a break don't get stuck (workersUnstuck). SetRestingForUnit sends a worker on
     a break to a random good building (a garden ...) and ends the break only on arrival.
     When the way gets blocked and no new route is found, processUnitMove retries every 40
     ticks for ever, and the worker never goes back to work. Such a worker is stopped where
     it stands; it picks another building, or the game ends the break if its time is up.

  5. Workers on their job don't get stuck either (workersJobsUnstuck). The same endless retry
     happens on a job's way (to the workplace, a stockpile, the granary ...): processUnitMove
     only checks the areas, which are rebuilt at most every 200 ticks and can say "reachable"
     while the route search keeps failing. After GIVE_UP failed searches in a row for the
     same destination, the worker gets the game's own answer for a worker that cannot reach
     its work: it fades out (state 0x6E) and the building takes on a new worker, who sets
     out from the campfire with fresh routes.

  6. Failed routes don't rebuild the whole map every time (rebuildLimit). When
     traceAndCommitPathPlan cannot walk a found route back (a spot whose path links only go one
     way), the game rebuilds every path link on the map, the area map and every building's
     links. A unit retries every 40 ticks and the rebuild lays the same links again, so a few
     stuck units made this most of the game's work (a profile: 79 rebuilds a second, 60% of
     the time). The rebuild now runs at most once every rebuildEveryTicks ticks; in between the
     route simply fails.

  Every address is found by pattern scan or read out of the instruction that uses it, so the
  module runs on Stronghold Crusader.exe and Stronghold_Crusader_Extreme.exe alike.
]]

local templates = require("templates")

local MODULE_NAME = "smarter-pathing"

local DEFAULTS = {
  assassinsResume = true,
  assassinsShortcut = true,
  ignoreQuarryPiles = true,
  workersUnstuck = true,
  workersJobsUnstuck = true,
  shortcutGroundSteps = 30,
  shortcutSavingPercent = 25,
  rebuildLimit = true,
  rebuildEveryTicks = 200,
}

---------------------------------------------------------------------------------------
-- What the game's code looks like where this module touches it
---------------------------------------------------------------------------------------

-- setDestinationForUnit, storing the final destination: mov word [esi+0x700], bp /
-- mov word [esi+0x702], di / mov word [esi+0xA08], bx. smarter-walls hooks the 7 bytes
-- just before it, so the pattern starts here.
local AOB_FINAL_DESTINATION = "66 89 AE 00 07 00 00 66 89 BE 02 07 00 00 66 89 9E 08 0A 00 00"
local FINAL_DESTINATION_SIZE = 14
-- The assassin climb flag (PathFindingState.allAssassinsUnk), cleared on the way out
-- (mov [flag], ebx) and tested further on (cmp [flag], ebx).
local CLIMB_FLAG_CLEAR = { 0x9D, { 0x89, 0x1D } }
local CLIMB_FLAG_TEST = { 0x1F4, { 0x39, 0x1D } }
-- setDestinationForUnit's route search (its call of PathFindingState::doPathfinding) belongs
-- to the route-search module; the shortcut is one of its policies. Order 100: it compares
-- candidate searches, so it runs outside policies that change what one search sees
-- (Gatehouse Fixes' gate rules, 200).
local ROUTE_POLICY = { id = "smarter-pathing.assassinsShortcut", order = 100 }
-- PathFindingState::bindPathPlanToAlgorithmStateAndReset: the route is written to the
-- buffer at +0x1BB38 (0x190 bytes, four bits a step), its length is +0x1BB3C.
local AOB_BIND_PLAN = "8B 44 24 04 89 81 38 BB 01 00 C7 81 3C BB 01 00 00 00 00 00 C2 04 00"
local PF_PLAN = 0x1BB38
local PF_PLAN_LENGTH = 0x1BB3C
local PLAN_BYTES = 0x190

-- aggressiveStanceTargetBuildingAtRange: an enemy building found near an aggressive unit is
-- passed over when its type's entry in a byte table is 0 (stockpile, keeps, campfire,
-- parade grounds ...): add eax, -10 / cmp eax, 0x3F / ja / movzx eax, byte [eax+table].
local AOB_AGGRESSIVE_SKIP = "83 C0 F6 83 F8 3F 77 0E 0F B6 80 ? ? ? ? FF 24 85"
local AGGRESSIVE_SKIP_TABLE = 11
local AGGRESSIVE_SKIP_FIRST = 10
local QUARRY_STOCKPILE = 21

-- SetRestingForUnit(unit), its start (8 bytes) and add word [esi+units+idle], 1 at +0x10
-- (rebalancer changes that 1, so it is left out of the pattern).
local AOB_RESTING = "53 55 56 57 8B 7C 24 14 8B F7 69 F6 90 04 00 00 66 83 86 ? ? ? ?"
local RESTING_SIZE = 8
local RESTING_IDLE_OPERAND = 19

-- processUnitMove, a failed new route search: mov eax, [esp+0x14] / pop edi / pop esi /
-- pop ebp / mov word [eax], 0x28 (try again in 40 ticks) ...
local AOB_ROUTE_FAILED = "8B 44 24 14 5F 5E 5D 66 C7 00 28 00 33 C0 5B 83 C4 08 C2 08 00"
local ROUTE_FAILED_SIZE = 5
-- Unit types with a job that walk between buildings: woodcutter, fletcher, hunter, quarry
-- mason, quarry worker, ox, pitchman, the four farmers, miller, baker, brewer, pole turner,
-- blacksmith, armourer, tanner, iron miner and his fetcher, priest, healer, innkeeper.
local JOB_WORKER_TYPES = { 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
  31, 32, 33, 34, 36 }
local TYPE_COUNT = 80
local GIVE_UP = 5                 -- failed searches in a row, 40 ticks apart
local STATE_BREAK = 0x79
local STATE_FADE = 0x6E
local U_STATE = 0x2C0
local U_TICKS = 0x2C8

-- Unit layout, relative to UnitsState + unit * 0x490 (the same in both exes).
local UNITS_FROM_STATE = 0x614
local U_TYPE = 0x8E
local U_DEST_X = 0xEC
local U_DEST_Y = 0xEE
-- ... and relative to the unit itself.
local WORKER_FIELDS = {
  U_X = 0xC4, U_Y = 0xC6,
  U_ROUTE_X = 0xC8, U_ROUTE_Y = 0xCA,   -- where the current route ends
  U_TILE = 0xD4, U_DEST_TILE = 0xD8,
  U_DEST_X = U_DEST_X, U_DEST_Y = U_DEST_Y,
  U_MOVING = 0xF6, U_PLAN_INDEX = 0xFA, U_PLAN_SIZE = 0xFC, U_MOVE_2D2 = 0x2D2,
  U_IDLE = 0x30A, U_TARGET = 0x30E,     -- break ticks so far, and how long it may last
  U_DEST_NEEDED = 0x374,                -- 0 while walking to the break building
  U_RETRY = 0x3F4,                      -- ticks until a failed route is tried again
}
local U_IDLE = WORKER_FIELDS.U_IDLE

-- traceAndCommitPathPlan's failure branch: mov edi, [esp+0x10] / add dword [edi+0x78], 1 /
-- mov ecx, edi / mov dword [edi+0x1BB3C], 0 / call updatePathLinkageLayerForEachBuilding...
-- The scan starts at its mov ecx, edi (Improved Tunnelers puts a jump on the 8 bytes before).
-- The rebuild's first call is at +0x0C; the branch pops and returns (ret 0x14) at +0x31.
local AOB_TRACE_FAILED = "8B CF C7 87 3C BB 01 00 00 00 00 00 E8 ? ? ? ? 6A 01 8B CF E8"
local TRACE_FAILED_CALL = 0x0C
local TRACE_FAILED_DONE = { 0x31, { 0x5D, 0x5B, 0x5E, 0x5F, 0x83, 0xC4, 0x0C, 0xC2, 0x14, 0x00 } }
-- The game's tick counter: mov edx, [ticks] in updateUnits.
local AOB_TICKS = "8B 87 50 0A 00 00 8B 8F 98 09 00 00 8B 15"
local TICKS_OPERAND = 0x0E

local ASSASSIN = 73
local MAX_UNITS = 0x10000

-- The saved game entry: the ids of the assassins that may climb, two bytes each.
local SAVE_SECTION = "smarter-pathing"
local SAVE_CLIMBERS = "assassin-climbers-v1.bin"

---------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------

local function scan(pattern, purpose)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok or not address or address == 0 then
    error(MODULE_NAME .. ": could not find " .. purpose)
  end
  return address
end

local function expectBytes(address, bytes, purpose)
  for index, byte in ipairs(bytes) do
    if (core.readByte(address + index - 1) & 0xFF) ~= byte then
      error(string.format("%s: %s at 0x%X is not the code this module knows", MODULE_NAME,
        purpose, address))
    end
  end
end

local function readOperand(base, site, purpose)
  expectBytes(base + site[1], site[2], purpose)
  return core.readInteger(base + site[1] + #site[2])
end

-- FASM gets a fixed 64 KB for source, symbols and output: only pass what a script uses.
local function assemble(script, values)
  local used = {}
  for name, value in pairs(values) do
    if script:find("%f[%w_]" .. name .. "%f[^%w_]") then
      used[name] = value
    end
  end
  return core.allocateAssembly(script, used)
end

local function jumpTo(address, target, size)
  local code = { 0xE9, core.itob(core.getRelativeAddress(address, target, -5)) }
  for _ = 6, size do
    code[#code + 1] = 0x90
  end
  core.writeCode(address, code)
end

local function setting(config, name)
  if type(config) == "table" and config[name] ~= nil then
    return config[name] == true
  end
  return DEFAULTS[name]
end

local function number(config, name, low, high)
  local value = type(config) == "table" and tonumber(config[name]) or nil
  if value == nil then
    value = DEFAULTS[name]
  end
  return math.max(low, math.min(high, math.floor(value)))
end

---------------------------------------------------------------------------------------
-- Saved games
---------------------------------------------------------------------------------------

-- Only climb orders are persisted. Retry records are local to the loaded world.
local function registerWorldState(climbers, failures, limiter)
  local function reset()
    if climbers then core.setMemory(climbers, 0, MAX_UNITS) end
    if failures then core.setMemory(failures, 0, MAX_UNITS * 5) end
    if limiter then core.setMemory(limiter, 0, 12) end
  end

  modules["map-extensions"]:registerSection(SAVE_SECTION, {
    initialize = reset,

    serialize = function(self, handle)
      if not climbers then return end
      local ids = {}
      for position in core.readString(climbers, MAX_UNITS):gmatch("()[^\0]") do
        ids[#ids + 1] = string.pack("<I2", position - 1)
      end
      handle:put(SAVE_CLIMBERS, table.concat(ids))
    end,

    deserialize = function(self, handle)
      reset()
      if not climbers or not handle:exists(SAVE_CLIMBERS) then
        return
      end
      local data = handle:get(SAVE_CLIMBERS)
      for offset = 1, #data - 1, 2 do
        core.writeByte(climbers + string.unpack("<I2", data, offset), 1)
      end
    end,
  })
end

---------------------------------------------------------------------------------------
-- Enable
---------------------------------------------------------------------------------------

local function climbFlag()
  local site = scan(AOB_FINAL_DESTINATION, "where setDestinationForUnit stores the destination")
  local flag = readOperand(site, CLIMB_FLAG_CLEAR, "the assassin climb flag")
  if readOperand(site, CLIMB_FLAG_TEST, "the assassin climb flag test") ~= flag then
    error(MODULE_NAME .. ": the assassin climb flag is not the one this module knows")
  end
  return site, flag
end

local function enable(self, config)
  -- Registered first: if route-search cannot take the route search, nothing is changed.
  local routes, route
  if setting(config, "assassinsShortcut") then
    routes = modules["route-search"]
    if not routes or (routes.version or 0) < 1 then
      error(MODULE_NAME .. ": the assassin shortcut needs the route-search module (version 1)")
    end
    route = routes:addPolicy(ROUTE_POLICY)
  end

  local climbers, failures, limiter
  if setting(config, "workersUnstuck") then
    local site = scan(AOB_RESTING, "the workers' break (SetRestingForUnit)")
    local values = {
      UNITS = core.readInteger(site + RESTING_IDLE_OPERAND) - U_IDLE,
      RESUME = site + RESTING_SIZE,
    }
    for name, offset in pairs(WORKER_FIELDS) do
      values[name] = offset
    end
    jumpTo(site, assemble(templates.restUnstuck, values), RESTING_SIZE)
  end

  if setting(config, "workersJobsUnstuck") then
    local site = scan(AOB_ROUTE_FAILED, "processUnitMove's failed route search")
    local data = core.allocate(TYPE_COUNT + MAX_UNITS * 5, true)
    local jobWorkers = data
    failures = data + TYPE_COUNT
    for _, unitType in ipairs(JOB_WORKER_TYPES) do
      core.writeByte(jobWorkers + unitType, 1)
    end
    jumpTo(site, assemble(templates.jobGiveUp, {
      UNITS_FROM_STATE = UNITS_FROM_STATE,
      U_TYPE = U_TYPE,
      U_STATE = U_STATE,
      U_TICKS = U_TICKS,
      U_DEST_TILE = WORKER_FIELDS.U_DEST_TILE,
      TYPE_COUNT = TYPE_COUNT,
      JOB_WORKERS = jobWorkers,
      STATE_BREAK = STATE_BREAK,
      STATE_FADE = STATE_FADE,
      MAX_UNITS = MAX_UNITS,
      FAIL_TILES = data + TYPE_COUNT,
      FAIL_COUNTS = data + TYPE_COUNT + MAX_UNITS * 4,
      GIVE_UP = GIVE_UP,
      RESUME = site + ROUTE_FAILED_SIZE,
    }), ROUTE_FAILED_SIZE)
  end

  if setting(config, "ignoreQuarryPiles") then
    local site = scan(AOB_AGGRESSIVE_SKIP, "the aggressive stance's building list")
    local skip = core.readInteger(site + AGGRESSIVE_SKIP_TABLE)
    local entry = skip + QUARRY_STOCKPILE - AGGRESSIVE_SKIP_FIRST
    if core.readByte(skip) & 0xFF ~= 0 or core.readByte(entry) & 0xFF > 1 then
      error(MODULE_NAME .. ": the aggressive stance's building list is not the one this module knows")
    end
    core.writeCode(entry, { 0 })
  end

  if route then
    local _, flag = climbFlag()
    scan(AOB_BIND_PLAN, "where a route is written")
    local choice = assemble(templates.climbChoice, {
      CLIMB_FLAG = flag,
      NEXT = route.next,
      UNIT = route.unit,
      UNIT_DEST = UNITS_FROM_STATE + U_DEST_X,
      UNIT_2D2 = UNITS_FROM_STATE + WORKER_FIELDS.U_MOVE_2D2,
      SAVED_ORDER = core.allocate(8, true),
      GROUND_ENOUGH = number(config, "shortcutGroundSteps", 1, 800),
      KEEP_PERCENT = 100 - number(config, "shortcutSavingPercent", 0, 90),
      PLAN = PF_PLAN,
      PLAN_LENGTH = PF_PLAN_LENGTH,
      PLAN_BYTES = PLAN_BYTES,
      SAVED_PLAN = core.allocate(PLAN_BYTES, true),
    })
    routes:enablePolicy(ROUTE_POLICY.id, choice)
  end

  if setting(config, "rebuildLimit") then
    local site = scan(AOB_TRACE_FAILED, "traceAndCommitPathPlan's failure branch")
    expectBytes(site + TRACE_FAILED_DONE[1], TRACE_FAILED_DONE[2], "traceAndCommitPathPlan's failure branch")
    local call = site + TRACE_FAILED_CALL
    limiter = core.allocate(12, true)
    local limit = assemble(templates.rebuildLimit, {
      TICKS = core.readInteger(scan(AOB_TICKS, "the game tick counter") + TICKS_OPERAND),
      LAST = limiter,
      SKIPPED = limiter + 4,
      HAS_REBUILT = limiter + 8,
      LIMIT = number(config, "rebuildEveryTicks", 1, 100000),
      REBUILD = (call + 5 + core.readInteger(call + 1)) & 0xFFFFFFFF,
      DONE = site + TRACE_FAILED_DONE[1],
    })
    core.writeCode(call, { 0xE8, core.itob(core.getRelativeAddress(call, limit, -5)) })
  end

  if setting(config, "assassinsResume") then
    local site, flag = climbFlag()
    climbers = core.allocate(MAX_UNITS, true)
    jumpTo(site, assemble(templates.remember, {
      UNIT_TYPE = UNITS_FROM_STATE + U_TYPE,
      DEST_X = UNITS_FROM_STATE + U_DEST_X,
      DEST_Y = UNITS_FROM_STATE + U_DEST_Y,
      ASSASSIN = ASSASSIN,
      MAX_UNITS = MAX_UNITS,
      CLIMB_FLAG = flag,
      CLIMBERS = climbers,
      RESUME = site + FINAL_DESTINATION_SIZE,
    }), FINAL_DESTINATION_SIZE)
  end
  if climbers or failures or limiter then
    registerWorldState(climbers, failures, limiter)
  end
end

return {
  enable = enable,
  disable = function(self, config) end,
}
