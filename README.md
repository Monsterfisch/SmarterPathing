# Smarter Pathing

## UCP package

Helps workers recover from blocked routes and assassins resume their orders after a fight. You can also limit costly path rebuilds and configure how much time a climb must save before assassins leave the ground route.

- Module directory: `module/`
- Targets: Stronghold Crusader 1.41 and Stronghold Crusader Extreme 1.41
- Requires UCP framework 3.0.7 and frontend 1.0.2 or a compatible later version
- Requires Map Extensions 1.x for map and save load callbacks
- Requires Route Search 1.x (`route-search`, in the UCP3 Fixes repository) for the assassin shortcut


A UCP3 module for Stronghold Crusader and Stronghold Crusader Extreme that makes units find
their way better. Assassins carry on to where they were sent after a fight instead of
stopping where it ended.

What the module does, in plain English, is in `module/locale/description-en.md`.

Presets can set `smarter-pathing.rebuildEveryTicks` (200) for the full path rebuild
interval, `smarter-pathing.shortcutGroundSteps` (30) for the minimum walking distance,
and `smarter-pathing.shortcutSavingPercent` (25) for the minimum saving from climbing.

## What is in here

| Folder | |
|---|---|
| `module/` | the module itself - this is the source of truth, edited in place |
| `tools/publish.py` | copies `module/` into the game's module folder under a new version |

## Working on it

1. Edit under `module/`.
2. `python tools/publish.py --bump` - raises the last version slot and copies the module to
   `ucp/modules/smarter-pathing-<version>`, leaving the build before it installed and
   clearing anything older.
3. In the UCP GUI press F5, then apply. `ucp-config.yml` is never edited by hand: the apply
   button moves the pin.
4. Commit and tag: `git commit -am "<version> - <what changed>" && git tag v<version>`.

## How it works

* An assassin climbs walls only while `PathFindingState.allAssassinsUnk` is set for its
  route search. The game sets it only where an order is given, for a group of assassins
  alone, so the searches that follow - after a fight (`resumeMovementAfterInterruption`) or
  when the way is blocked (`processUnitMove`) - run without it and fail for a target on a
  wall.
* `setDestinationForUnit` is hooked where it stores the order's final destination (unit
  `+0xEC/+0xEE`): an assassin's order remembers whether it came with the flag, and a search
  for the same destination again gets the flag back.
* That memory (the ids of the assassins that may climb) is stored in saved games through the
  `map-extensions` module's own section, and wiped for a game started from a map.
* Climb shortcut: a policy (order 100) of the `route-search` module, which owns
  setDestinationForUnit's call of `doPathfinding`. Each of its searches goes through the
  policy's `next`, so Gatehouse Fixes' gate rules (order 200) run inside both, for the same
  unit. With the climb flag set, the search first runs without it. A ground route under the
  step limit is kept; a longer one is copied aside (`PathFindingState+0x1BB38`, 0x190 bytes)
  while the climbing search runs, and put back unless the climbing route is shorter by the
  set percentage. When a route is returned, the order's final destination (unit
  `+0xEC/+0xEE`) and unit `+0x2D2` are put back as they were, in case a policy inside
  stopped the unit for a candidate that found no route.
* Workers on a break: `SetRestingForUnit` (state 0x79) ignores whether the route to the good
  building it picked was found, and ends the break only on arrival. A worker whose route is
  blocked and whose new search failed waits in `processUnitMove` (unit `+0x3F4`) and retries
  for ever. Hooked at its start: such a worker is stopped as if it had arrived, and picks
  another building unless its break time (`+0x30A` vs `+0x30E`) is up.
* Workers on their job: the same endless retry happens on job routes, because
  `processUnitMove` only checks areas (rebuilt at most every 200 ticks) before its new search.
  Hooked where that search has failed: a job worker failing 5 times in a row for the same
  destination tile gets state 0x6E (fade out), the game's own answer for a worker whose
  destination area can't be reached, and the building takes on a new worker.
* Quarry stockpiles: `aggressiveStanceTargetBuildingAtRange` passes over enemy building types
  whose byte in a type table is 0. The stockpile (10) is 0, the quarry stockpile (21) was 1;
  it is set to 0.

## Vanilla and Recommended

Every option of the module is off by default, so the module alone plays like the original
game. Two plugins in this repository form the Smarter Pathing family in the launcher:
`smarter-pathing-recommended` (offered first) switches on the recommended settings, `smarter-pathing-vanilla`
keeps everything off. Plugins that build on the module set the options they need themselves.
