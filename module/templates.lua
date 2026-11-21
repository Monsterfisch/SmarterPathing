-- FASM sources. Upper-case names are filled in by init.lua.
local templates = {}

-- setDestinationForUnit, where it stores the order's final destination:
-- mov word [esi+DEST_X], bp / mov word [esi+DEST_Y], di (14 bytes).
-- esi = UnitsState + unit*0x490, ebp = x, edi = y, [esp+0x1C] = unit, [esp+0x28] = mode.
-- The flags of the cmp ecx, ebp just before are still needed afterwards.
--
-- An assassin climbs walls only when CLIMB_FLAG is set for its route search, and the game
-- sets it only when the order is given. Remember per unit whether its order was given with
-- it; a search for the same destination again (after a fight, or after being blocked on the
-- way) gets it back.
templates.remember = [[
  pushfd
  cmp word [esi + UNIT_TYPE], ASSASSIN
  jne write_destination
  cmp dword [esp + 0x2C], 0
  jne write_destination
  push eax
  push ecx
  mov ecx, [esp + 0x28]
  cmp ecx, MAX_UNITS
  jae finish
  mov eax, [CLIMB_FLAG]
  test eax, eax
  jnz note_order
  cmp bp, [esi + DEST_X]
  jne note_order
  cmp di, [esi + DEST_Y]
  jne note_order
  cmp byte [CLIMBERS + ecx], 0
  je finish
  mov dword [CLIMB_FLAG], 1
  jmp finish
note_order:
  mov [CLIMBERS + ecx], al
finish:
  pop ecx
  pop eax
write_destination:
  mov word [esi + DEST_X], bp
  mov word [esi + DEST_Y], di
  popfd
  jmp RESUME
]]

-- Stands in for PathFindingState::doPathfinding(owner, canClimbTowers) at its call in
-- setDestinationForUnit (thiscall, ecx = PathFindingState, ret 8). SEARCH is whatever that
-- call went to before (the game's search, or another module's wrapper of it).
--
-- A search with CLIMB_FLAG set (assassins sent on their own) first looks for a route on the
-- ground. A ground route shorter than GROUND_ENOUGH steps is taken as it is. A longer one is
-- kept aside while the climbing search runs, and the climbing route is taken only when it
-- needs at most KEEP_PERCENT percent of the ground route's steps (or there is no ground
-- route at all).
templates.climbChoice = [[
  cmp dword [CLIMB_FLAG], 0
  jne choose
  jmp SEARCH
choose:
  push ebx
  push esi
  push edi
  push ebp
  mov esi, ecx
  mov dword [CLIMB_FLAG], 0
  push dword [esp + 0x18]
  push dword [esp + 0x18]
  mov ecx, esi
  call SEARCH
  mov dword [CLIMB_FLAG], 1
  mov ebx, eax
  test ebx, ebx
  jle climb
  cmp ebx, GROUND_ENOUGH
  jl take_ground
  mov ebp, esi
  mov esi, [ebp + PLAN]
  mov edi, SAVED_PLAN
  mov ecx, PLAN_BYTES
  cld
  rep movsb
  mov esi, ebp
climb:
  push dword [esp + 0x18]
  push dword [esp + 0x18]
  mov ecx, esi
  call SEARCH
  test eax, eax
  jle ground_again
  test ebx, ebx
  jle finish
  mov ecx, eax
  imul ecx, ecx, 100
  mov edx, ebx
  imul edx, edx, KEEP_PERCENT
  cmp ecx, edx
  jle finish
ground_again:
  test ebx, ebx
  jle finish
  mov ebp, esi
  mov edi, [ebp + PLAN]
  mov esi, SAVED_PLAN
  mov ecx, PLAN_BYTES
  cld
  rep movsb
  mov esi, ebp
  mov [esi + PLAN_LENGTH], ebx
take_ground:
  mov eax, ebx
finish:
  pop ebp
  pop edi
  pop esi
  pop ebx
  ret 8
]]

-- The start of SetRestingForUnit(unit), cdecl: push ebx / push ebp / push esi / push edi /
-- mov edi, [esp+0x14] (8 bytes). A worker on a break (state 0x79) walks to a good building
-- picked at random, and the break ends only once it has arrived. When its way there gets
-- blocked and no new route is found, processUnitMove makes it wait (U_RETRY) and try again
-- for ever, so it never arrives and never goes back to work.
-- Such a worker is stopped where it stands, as if it had arrived. If its break time is not
-- used up, it picks another building to go to; otherwise the game ends the break.
-- traceAndCommitPathPlan, its failure branch: the walk-back from the target found no step
-- (mov edi, [esp+0x10] / add dword [edi+0x78], 1). The game then rebuilds every path link on
-- the map, the area map and every building's links, and returns no route. A spot whose links
-- only go one way makes the same routes fail on every retry, and the rebuild lays the same
-- links again - so it is let through at most once every LIMIT ticks; in between the route
-- just fails (no plan, as the game leaves it), which costs nothing.
-- It takes the place of the branch's first call (ecx = PathFindingState): let through, it goes
-- on into the game's function; held back, it drops its return address and leaves the branch.
-- The branch's opening bytes stay as they are (Improved Tunnelers hooks those).
templates.rebuildLimit = [[
  mov eax, [TICKS]
  cmp dword [HAS_REBUILT], 0
  je rebuild
  mov edx, eax
  sub edx, [LAST]
  cmp edx, LIMIT
  jb skip
rebuild:
  mov dword [HAS_REBUILT], 1
  mov [LAST], eax
  jmp REBUILD
skip:
  add dword [SKIPPED], 1
  add esp, 4
  jmp DONE
]]

templates.restUnstuck = [[
  mov eax, [esp + 4]
  imul eax, eax, 0x490
  add eax, UNITS
  cmp word [eax + U_RETRY], 0
  jle original
  cmp word [eax + U_MOVING], 0
  je original
  cmp word [eax + U_DEST_NEEDED], 0
  jne original
  push ecx
  xor ecx, ecx
  mov [eax + U_RETRY], cx
  mov [eax + U_MOVING], cx
  mov [eax + U_PLAN_INDEX], cx
  mov [eax + U_PLAN_SIZE], cx
  mov [eax + U_MOVE_2D2], cx
  mov cx, [eax + U_X]
  mov [eax + U_DEST_X], cx
  mov [eax + U_ROUTE_X], cx
  mov cx, [eax + U_Y]
  mov [eax + U_DEST_Y], cx
  mov [eax + U_ROUTE_Y], cx
  mov ecx, [eax + U_TILE]
  mov [eax + U_DEST_TILE], ecx
  mov cx, [eax + U_IDLE]
  cmp cx, [eax + U_TARGET]
  jg stopped
  mov word [eax + U_DEST_NEEDED], 1
stopped:
  pop ecx
original:
  push ebx
  push ebp
  push esi
  push edi
  mov edi, [esp + 0x14]
  jmp RESUME
]]

-- processUnitMove, where a walking unit's new route search (after its way was blocked) has
-- failed: mov eax, [esp+0x14] / pop edi (5 bytes); the game then waits 40 ticks and tries
-- again, for ever. esi = UnitsState, edi = unit * 0x490, [esp+0x1C] = unit.
-- A worker on its job that fails GIVE_UP times in a row for the same destination gets the
-- game's own answer for a worker that cannot reach where it works: it fades out (state
-- 0x6E) and the building takes on a new worker. Workers on a break are left to the break
-- hook, which sends them somewhere else.
templates.jobGiveUp = [[
  lea eax, [esi + edi + UNITS_FROM_STATE]
  movzx ecx, word [eax + U_TYPE]
  cmp ecx, TYPE_COUNT
  jae original
  cmp byte [JOB_WORKERS + ecx], 0
  je original
  cmp word [eax + U_STATE], STATE_BREAK
  je original
  mov ecx, [esp + 0x1C]
  cmp ecx, MAX_UNITS
  jae original
  mov edx, [eax + U_DEST_TILE]
  cmp edx, [FAIL_TILES + ecx*4]
  je same_destination
  mov [FAIL_TILES + ecx*4], edx
  mov byte [FAIL_COUNTS + ecx], 0
same_destination:
  add byte [FAIL_COUNTS + ecx], 1
  cmp byte [FAIL_COUNTS + ecx], GIVE_UP
  jb original
  mov byte [FAIL_COUNTS + ecx], 0
  mov dword [FAIL_TILES + ecx*4], 0
  mov word [eax + U_STATE], STATE_FADE
  mov word [eax + U_TICKS], 0
original:
  mov eax, [esp + 0x14]
  pop edi
  jmp RESUME
]]

return templates
