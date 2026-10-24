-- Headless test for THE OUT LAP'S FIRST CHECKPOINT (track.firstCheckpoint).
--
-- A grid part way round the circuit used to arm CP 1 at GO. CP 1 is past the
-- line, so the run from the grid to the line had nothing lit, and the out lap
-- then went on round to CP 1 and all the way back to the line: a part lap plus
-- a whole one before lap 2. The layout now names the first gate ahead of the
-- grid, and the out lap arms that one.
--
-- The rule it must not break: the out lap still ends on the armed gate, never on
-- a bare line crossing (tests/out_lap_line_test.lua). Starting the sequence
-- later skips gates behind the grid; it never adds a shortcut.
--
-- Run from the repo root: lua5.3 tests/first_checkpoint_test.lua
local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- Stubs (as tests/out_lap_line_test.lua)
-- ---------------------------------------------------------------------------
local vec3mt = {}
vec3mt.__index = vec3mt
vec3mt.__add = function (a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function (a, s) return vec3(a.x * s, a.y * s, a.z * s) end
vec3 = function (x, y, z) return setmetatable({ x = x, y = y, z = z }, vec3mt) end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
ColorF = function (r, g, b, a) return { r, g, b, a } end
ColorI = function (r, g, b, a) return { r, g, b, a } end
String = function (s) return s end
debugDrawer = {
  drawCylinder = function () end, drawTextAdvanced = function () end,
  drawQuadSolid = function () end, drawTriSolid = function () end,
}
color = function () return 0 end

local veh = { id = 7, x = 0, y = 0, z = 0 }
function veh:getID() return self.id end
function veh:getPosition() return { x = self.x, y = self.y, z = self.z } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 40, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:setPositionRotation() end
function veh:queueLuaCommand() end
function veh:setMeshAlpha() end

getPlayerVehicle = function (_) return veh end
be = { getPlayerVehicle = function () return veh end }
getAllVehicles = function () return { veh } end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt = { getConfig = function () return { parts = {}, vars = {} } end }
log = function () end

local routeState = nil
local lapsDone = {}
local lastProgress = nil
guihooks = { trigger = function (event, payload)
  if event == 'RaceManagerRoute' then routeState = payload end
  if event == 'RaceManagerLapDone' then lapsDone[#lapsDone + 1] = payload end
  if event == 'RaceManagerProgress' then lastProgress = payload end
end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
local handlers = {}
AddEventHandler = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local function serverState(t)
  t.rmProtocol = 2
  if t.drivers == nil then t.drivers = {} end
  handlers['RM_Update'](t)
  RM.onUpdate(0.016)
end

local function drive(toY, step)
  step = step or 5
  while veh.y < toY do
    veh.y = math.min(veh.y + step, toY)
    RM.onUpdate(0.016)
  end
end

-- Past the 2 s double-fire guard on the line (TUNE.LAP_DEBOUNCE).
local function settle()
  for _ = 1, 200 do RM.onUpdate(0.016) end
end

-- A straight "circuit": gates score both ways, so the harness can drive +y only
-- and teleport back. CP 1..5 at y = 1100..1500, the line at 1600.
local function route()
  local cps = {}
  for i = 1, 5 do cps[i] = { x = 0, y = 1000 + i * 100, z = 0, hx = 0, hy = 1 } end
  cps[6] = { x = 0, y = 1600, z = 0, hx = 0, hy = 1 }
  return cps
end
local function apply(name, first, gridY)
  handlers['RM_ApplyLayout']({
    name = name, width = 20, height = 8, depth = 2,
    checkpoints = route(),
    startPositions = { { x = 0, y = gridY, z = 0, hx = 0, hy = 1 } },
    firstCheckpoint = first,
  })
end

-- ---------------------------------------------------------------------------
-- 1. A RACE FROM A GRID BETWEEN CP 2 AND CP 3
-- ---------------------------------------------------------------------------
apply('part way round', 3, 1250)
check(#(routeState.waypoints or {}) == 6, 'the fixture loaded')
check(routeState.firstCheckpoint == 3, 'the layout\'s first checkpoint reaches the panel')
check(routeState.gridOffLine == true, 'and the grid reads as off the line')

veh.x, veh.y, veh.z = 0, 1250, 0
serverState({ phase = 'grid', qualiOutLap = true, totalLaps = 5 })
check(routeState.nextWp == 3, 'on the grid, CP 3 is the gate lit ahead, as GO will arm it')

serverState({ phase = 'racing', qualiOutLap = true, totalLaps = 5 })
check(routeState.nextWp == 3, 'at GO the out lap arms CP 3, not CP 1 behind the grid')
lapsDone = {}
settle()
check(lastProgress and lastProgress.cp == 2,
  'progress counts the gates behind the grid as done, the same for every car')

drive(1350)
check(routeState.nextWp == 4, 'clearing CP 3 arms CP 4')
check(#lapsDone == 0, 'and ends nothing')

drive(1550)
check(routeState.nextWp == 6, 'CP 4 and CP 5 cleared: the line is next')
check(#lapsDone == 0, 'still on the out lap')

drive(1650)
check(#lapsDone == 1 and lapsDone[1].outLap == true,
  'the line ends the part lap as an untimed out lap')
check(routeState.nextWp == 1, 'and lap 2 starts at CP 1 like any lap')

-- ---------------------------------------------------------------------------
-- 2. NO OUT LAP, NO EFFECT
-- ---------------------------------------------------------------------------
-- The server decides whether an out lap is owed. Without one the first lap is
-- timed, and starting it at CP 3 would time a part lap.
serverState({ phase = 'waiting' })
veh.y = 1250
serverState({ phase = 'racing', qualiOutLap = false, totalLaps = 5 })
check(routeState.nextWp == 1, 'with no out lap owed, GO arms CP 1 whatever the layout says')

-- Qualifying's out lap takes the same start.
serverState({ phase = 'waiting' })
serverState({ phase = 'qualifying', qualiOutLap = true })
check(routeState.nextWp == 3, 'qualifying\'s out lap starts at the first checkpoint too')
serverState({ phase = 'waiting' })

-- ---------------------------------------------------------------------------
-- 3. A LAYOUT THAT NEVER SET IT
-- ---------------------------------------------------------------------------
apply('ordinary', nil, 1250)
check(routeState.firstCheckpoint == 1, 'absent is CP 1')
serverState({ phase = 'racing', qualiOutLap = true, totalLaps = 5 })
check(routeState.nextWp == 1, 'and the out lap arms CP 1 as it always has')
serverState({ phase = 'waiting' })

-- Out of range is CP 1, not a gate that does not exist.
apply('too far', 9, 1250)
check(routeState.firstCheckpoint == 1, 'a first checkpoint past the route reads as CP 1')

-- ---------------------------------------------------------------------------
-- 4. IT MAKES THE OUT LAP, EVEN NEAR THE LINE
-- ---------------------------------------------------------------------------
-- gridIsOff's distance test is 250 m. A short circuit can grid part way round
-- inside that, and naming a first checkpoint is the admin saying so.
apply('close, unset', nil, 1550)
check(routeState.gridOffLine == false, 'a grid 50 m from the line, facing it, is on the line')
apply('close, set', 6, 1550)
check(routeState.gridOffLine == true, 'until a first checkpoint says otherwise')
check(routeState.firstCheckpoint == 6, 'the line itself may be the first gate')

-- ---------------------------------------------------------------------------
-- 5. A SPRINT HAS NO OUT LAP
-- ---------------------------------------------------------------------------
handlers['RM_ApplyLayout']({
  name = 'stage', width = 20, height = 8, depth = 2, pointToPoint = true,
  checkpoints = route(), firstCheckpoint = 3,
  startPositions = { { x = 0, y = 1250, z = 0, hx = 0, hy = 1 } },
})
serverState({ phase = 'racing', qualiOutLap = true, totalLaps = 1 })
check(routeState.nextWp == 1, 'a point-to-point stage starts at its first gate regardless')
serverState({ phase = 'waiting' })

-- ---------------------------------------------------------------------------
-- 6. THE EDITOR KEEPS IT ON THE SAME GATE
-- ---------------------------------------------------------------------------
-- It is a gate number, like a branch gate's slot, so inserting, removing and
-- reordering gates renumber it.
apply('editing', nil, 1250)
RM.setFirstCheckpoint(3)
check(routeState.firstCheckpoint == 3, 'the picker sets it')
RM.insertCheckpoint(2, { x = 0, y = 1150, z = 0, hx = 0, hy = 1 })
check(routeState.firstCheckpoint == 4, 'a gate inserted before it moves it along with its gate')
RM.removeCheckpoint(1)
check(routeState.firstCheckpoint == 3, 'a gate removed before it moves it back')
RM.reorderCheckpoint(3, 5)
check(routeState.firstCheckpoint == 5, 'reordering its gate takes it along')
RM.reorderCheckpoint(1, 5)
check(routeState.firstCheckpoint == 4, 'and a gate moved past it shifts it down')
RM.setFirstCheckpoint(99)
check(routeState.firstCheckpoint == 1, 'a number past the route is refused as CP 1')

RM.setFirstCheckpoint(2)
serverState({ phase = 'qualifying', qualiOutLap = true })
RM.setFirstCheckpoint(4)
check(routeState.firstCheckpoint == 2, 'it cannot be changed mid-session')
serverState({ phase = 'waiting' })

print(string.format('first_checkpoint_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
