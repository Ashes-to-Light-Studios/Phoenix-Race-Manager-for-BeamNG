-- Headless test for the results copy a logged-in admin's PC is sent
-- (RM_ResultsFile -> raceManager.onResultsFile).
--
-- The server owns this file's name and text, but they arrive over the wire and
-- land on the admin's disk, in the folder My Results opens in Explorer. So:
--
--   * only the name shape the server writes is kept. Explorer hides known
--     extensions, so results.txt.cmd shows as results.txt, and Clear My
--     Results deletes .txt only, so it would never go
--   * nothing bigger than the server ever sends is written
--   * a failed write says so. BeamNG's writeFile RETURNS nil on failure, it
--     does not raise, and a bare pcall reported every failure as saved
--
-- Run from the repo root: lua tests/results_copy_test.lua

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

-- ---------------------------------------------------------------------------
-- BeamNG / BeamMP stubs (lifecycle_test's set), plus the disk
-- ---------------------------------------------------------------------------
local handlers, notices, logs, writes = {}, {}, {}, {}
local writeMode = 'ok'     -- 'ok' | 'nil' (BeamNG's failure) | 'raise'

local veh = { id = 7 }
function veh:getID() return self.id end
function veh:getPosition() return { x = 0, y = 0, z = 0 } end
function veh:getRotation() return { x = 0, y = 0, z = 0, w = 1 } end
function veh:getDirectionVector() return { x = 0, y = 1, z = 0 } end
function veh:getVelocity() return { x = 0, y = 0, z = 0 } end
function veh:getJBeamFilename() return 'etk800' end
function veh:queueLuaCommand() end

be               = { getPlayerVehicle = function () return veh end }
getPlayerVehicle = function () return veh end
getAllVehicles   = function () return { veh } end
beamng_version   = '0.40.0.0'
vec3 = function (x, y, z) return { x = x, y = y, z = z } end
quat = function (x, y, z, w) return { x = x, y = y, z = z, w = w } end
log  = function (level, _, msg) logs[#logs + 1] = { level = level, msg = tostring(msg) } end
guihooks = { trigger = function (e, p)
  if e == 'RaceManagerNotice' then notices[#notices + 1] = p.msg end
end }

MPGameNetwork      = {}
MPConfig           = { getPlayerServerID = function () return 1 end }
TriggerServerEvent = function () end
AddEventHandler    = function (e, fn) handlers[e] = fn end
jsonEncode = function (t) return t end
jsonDecode = function (v) return v end
math.atan2 = math.atan2 or function (y, x) return math.atan(y, x) end
core_input_actionFilter = { setGroup = function () end, addAction = function () end }
core_vehicle_partmgmt   = { getConfig = function () return { parts = {}, vars = {} } end }

-- Nothing here touches the real disk.
FS = { directoryCreate = function () end }
writeFile = function (path, text)
  if writeMode == 'raise' then error('disk unavailable', 0) end
  if writeMode == 'nil' then return nil end
  writes[#writes + 1] = { path = path, text = text }
  return true
end

package.path = 'lua/ge/extensions/?.lua;' .. package.path
local RM = dofile('lua/ge/extensions/raceManager.lua')
RM.onExtensionLoaded()

local DIR = RM.RESULTS_LOCAL_DIR .. '/'
local GENERATED = '^results_%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d%.txt$'

-- Through the dispatch table, as BeamMP delivers it.
local function send(name, text)
  notices, logs, writes = {}, {}, {}
  handlers['RM_ResultsFile']({ name = name, text = text or 'P1    Cara\n' })
end
local function noticed(fragment)
  for _, m in ipairs(notices) do
    if tostring(m):find(fragment, 1, true) then return true end
  end
  return false
end

check(type(handlers['RM_ResultsFile']) == 'function', 'RM_ResultsFile is wired to a handler')

-- ---------------------------------------------------------------------------
-- 1. What the server sends is saved under its own name
-- ---------------------------------------------------------------------------
for _, name in ipairs({
  'results_2026-11-06_20-15-00.txt',
  'results_2026-11-06_20-15-00_2.txt',      -- two sessions closed in one second
  'derby_results_2026-11-06_21-02-11.txt',  -- the derby and drag names, if sent
}) do
  send(name)
  check(#writes == 1 and writes[1].path == DIR .. name,
    name .. ' is saved under its own name')
  check(#writes == 1 and writes[1].text == 'P1    Cara\n', 'with the text untouched')
  check(noticed('Results saved to your own copy: ' .. name), 'and the admin is told where')
end

-- ---------------------------------------------------------------------------
-- 2. Any other name is replaced, never used
-- ---------------------------------------------------------------------------
for _, name in ipairs({
  'results.txt.cmd', 'results_2026-11-06_20-15-00.txt.url', 'evil.bat', 'CON', 'NUL.txt',
  '..', '../../AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/x.bat',
  'C:/Windows/x.txt', 'results_1.txt:stream', 'results_2026-11-06.TXT',
  'results_' .. string.rep('1', 80) .. '.txt', string.rep('9', 5000) .. '.txt', '',
}) do
  send(name)
  local base = writes[1] and writes[1].path:sub(#DIR + 1)
  check(#writes == 1 and writes[1].path:sub(1, #DIR) == DIR,
    ('%q: one copy, in the results folder'):format(name:sub(1, 60)))
  check(base ~= nil and base ~= name and base:match(GENERATED) ~= nil,
    ('%q: saved under a name of our own, not the one sent (got %s)')
      :format(name:sub(1, 60), tostring(base):sub(1, 60)))
end
send(nil)
check(#writes == 1 and writes[1].path:sub(#DIR + 1):match(GENERATED) ~= nil,
  'a copy with no name is saved under a dated name, not one every copy overwrites')

-- ---------------------------------------------------------------------------
-- 3. Nothing bigger than the server ever sends
-- ---------------------------------------------------------------------------
send('results_2026-11-06_20-15-00.txt', string.rep('x', RM.RESULTS_LOCAL_MAX))
check(#writes == 1, 'a copy at the size limit is saved')
send('results_2026-11-06_20-15-00.txt', string.rep('x', RM.RESULTS_LOCAL_MAX + 1))
check(#writes == 0, 'one byte over is not written at all')
check(noticed('too large'), 'and the admin is told why')
check(RM.RESULTS_LOCAL_MAX >= 60000,
  'the limit is above what the server sends (MAX_RESULTS_PUSH, 60000)')

-- ---------------------------------------------------------------------------
-- 4. A failed write is reported as one
-- ---------------------------------------------------------------------------
for _, mode in ipairs({ 'nil', 'raise' }) do
  writeMode = mode
  send('results_2026-11-06_20-15-00.txt')
  check(not noticed('Results saved'),
    'writeFile ' .. (mode == 'nil' and 'returning nil' or 'raising')
      .. ' is not reported as saved')
  check(noticed('Could not save your results copy'), 'the admin is told it failed')
  local warned = false
  for _, l in ipairs(logs) do
    if l.level == 'W' and l.msg:find('Could not write', 1, true) then warned = true end
  end
  check(warned, 'and the log says so')
end
writeMode = 'ok'

print(string.format('results_copy_test: %d checks, %d failures', checks, fails))
if fails > 0 then os.exit(1) end
