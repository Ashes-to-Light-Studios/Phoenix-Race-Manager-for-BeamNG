-- Headless test for SAVE RESULTS in server/RaceManager/main.lua: where a
-- closing session's results go.
--
-- Every results file used to be written to the server's results folder AND
-- sent to every logged-in admin's PC, with no way to turn either off. Now both
-- are switches on the Admin panel (config.json saveResultsOnServer and
-- copyResultsToAdmins), OFF as shipped, so an admin chooses; Discord is its own
-- row. Pinned here:
--
--   * as shipped, a race writes no file and sends no copy, and the admins are
--     told the results went nowhere (a night is not lost without a word)
--   * each switch does what it says, alone and together, for races, derbies
--     and drag tournaments
--   * only the admin tier can change them, every admin's panel follows, and
--     they survive a restart (config.json)
--   * Restart from grid still puts both races in one file, wherever it is kept:
--     an admin's copy of the stopped race is replaced by one holding both, and
--     a server file deleted in between does not lose the stopped race
--
-- Run from the repo root: lua5.3 tests/results_save_test.lua

local connected = { [1] = 'Admin', [2] = 'Mod', [3] = 'Driver' }
local ADMIN, MOD, DRIVER = 1, 2, 3
local chat      = {}   -- { target, msg }
local events    = {}   -- every TriggerClientEvent: { target, event, payload }
local targeted  = {}   -- the last RM_Update sent to each pid on its own
local lastState = nil
local lastDerby = nil
local lastDrag  = nil
local timers    = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = { target = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    events[#events + 1] = { target = target, event = event, payload = payload }
    if event == 'RM_Update' then
      lastState = payload
      if target ~= -1 then targeted[target] = payload end
    end
    if event == 'RM_DerbyUpdate' then lastDerby = payload end
    -- Drag pushes are partial: merged, as the panel does.
    if event == 'RM_DragUpdate' then
      lastDrag = lastDrag or {}
      for k, v in pairs(payload) do lastDrag[k] = v end
    end
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function (name) timers[name] = true end,
  CancelEventTimer = function (name) timers[name] = nil end,
  RemoveVehicle = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

-- The clock the dated file names are read from, movable: a race and its rerun
-- close within one second here, and would otherwise get the same name anyway.
local realDate, dateShift = os.date, 0
os.date = function (fmt, t) return realDate(fmt, (t or os.time()) + dateShift) end

local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local function removeTree(path)
  if IS_WINDOWS then
    os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
  else
    os.execute('rm -rf "' .. path .. '"')
  end
end
removeTree('Resources')

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local RESULTS_DIR = 'Resources/Server/RaceManager/Data/results'
local CONFIG = 'Resources/Server/RaceManager/Data/config.json'
-- The same shape raceManager.onResultsFile keeps; anything else is renamed.
local CLIENT_NAME = '^[A-Za-z_]*results_[%d_%-]+%.txt$'

local function read(path)
  local f = path and io.open(path, 'r')
  if not f then return nil end
  local t = f:read('*a'); f:close()
  return t
end
local function count(text, needle)
  local n, at = 0, 1
  while text do
    local i = text:find(needle, at, true)
    if not i then break end
    n, at = n + 1, i + 1
  end
  return n
end
-- The .txt files in the server's results folder.
local function serverFiles()
  local cmd = IS_WINDOWS and ('dir /b "' .. RESULTS_DIR:gsub('/', '\\') .. '" 2>nul')
    or ('ls "' .. RESULTS_DIR .. '" 2>/dev/null')
  local p, out = io.popen(cmd), {}
  for line in p:lines() do
    if line:match('%.txt$') then out[#out + 1] = line end
  end
  p:close()
  return out
end
-- Since the logs were last cleared.
local function copiesTo(pid)
  local out = {}
  for _, e in ipairs(events) do
    if e.event == 'RM_ResultsFile' and e.target == pid then out[#out + 1] = e.payload end
  end
  return out
end
local function chatTo(pid, fragment)
  for _, c in ipairs(chat) do
    if (c.target == pid or c.target == -1) and c.msg:find(fragment, 1, true) then return c.msg end
  end
  return nil
end
local function announcedPath()
  for _, c in ipairs(chat) do
    local p = c.msg:match('(' .. RESULTS_DIR .. '/[%w%-_%.]+%.txt)')
    if p then return p end
  end
  return nil
end
local function denied(pid)
  for _, e in ipairs(events) do
    if e.event == 'RM_Denied' and e.target == pid then return true end
  end
  return false
end
local function clearLogs() chat, events = {}, {} end
local UNSAVED = 'were not saved anywhere'

-- A race: two laps, everyone home, the finish rule closing it at once.
local function lap(pid) RM_onLap(pid, '{"lapTime":60.0}') end
local function seconds(n) for _ = 1, math.floor(n * 10) do RM_Tick() end end
local function go()
  RM_onGenerateGrid(ADMIN)
  RM_onStartCountdown(ADMIN)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end
local function runRace()
  go()
  for _ = 1, 2 do for _, p in ipairs({ DRIVER, MOD, ADMIN }) do lap(p) end end
  seconds(6)
  check(lastState.phase == 'finished', 'the race finishes')
end
local function set(pid, json) RM_onSetResultsSave(pid, json) end

local function boot()
  dofile('server/RaceManager/main.lua')
  onInit()
  for pid in pairs(connected) do RM_onPlayerJoin(pid) end
  RM_onLogin(ADMIN, '{"password":"phoenix"}'); RM_onSetReadyCheck(ADMIN, '{"on":false}')
end

boot()
RM_onChangePassword(ADMIN, '{"password":"marshal","role":"moderator"}')
RM_onLogin(MOD, '{"password":"marshal"}')
RM_onSetRaceLimits(ADMIN, '{"laps":2,"seconds":0,"mode":"laps"}')
RM_onSetFinishRule(ADMIN, '{"after":1,"seconds":0}')

-- ---------------------------------------------------------------------------
-- 1. As shipped: saved nowhere, and the admins are told
-- ---------------------------------------------------------------------------
RM_onRequestState(ADMIN)
local s = targeted[ADMIN] and targeted[ADMIN].resultsSave
check(s ~= nil and s.server == false and s.admins == false,
  'both switches are off as shipped, and an admin\'s panel says so')
RM_onRequestState(DRIVER)
check(targeted[DRIVER] and targeted[DRIVER].resultsSave == nil, 'a driver is never sent them')
local cfg = read(CONFIG) or ''
check(cfg:find('"saveResultsOnServer"%s*:%s*false') and cfg:find('"copyResultsToAdmins"%s*:%s*false'),
  'config.json is written with both, off, so they can be found and edited')

clearLogs()
runRace()
check(#serverFiles() == 0, 'no file in the server\'s results folder')
check(#copiesTo(ADMIN) == 0 and #copiesTo(MOD) == 0, 'no copy sent to any admin')
check(chatTo(-1, 'Session complete!') ~= nil and announcedPath() == nil,
  'the session still closes in chat, with no path')
check(chatTo(ADMIN, UNSAVED) and chatTo(MOD, UNSAVED),
  'every admin logged in is told the results were not saved anywhere')
local toDriver = false
for _, c in ipairs(chat) do
  if c.target == DRIVER and c.msg:find(UNSAVED, 1, true) then toDriver = true end
end
check(not toDriver, 'and a driver is not')

-- A race stopped by Restart from grid is carried to its rerun, so it is the
-- rerun, holding both, that is warned about. Once, not twice.
clearLogs()
go()
lap(DRIVER); lap(MOD)
RM_onRestartFromGrid(ADMIN)
check(lastState.phase == 'grid', 'a race restarted with nothing kept still goes back to the grid')
check(chatTo(ADMIN, UNSAVED) == nil, 'the stopped race is not warned about: its rerun carries it')
clearLogs()
RM_onStartCountdown(ADMIN)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _ = 1, 2 do for _, p in ipairs({ DRIVER, MOD, ADMIN }) do lap(p) end end
seconds(6)
check(chatTo(ADMIN, UNSAVED) ~= nil, 'the rerun is')

-- ---------------------------------------------------------------------------
-- 2. The admin tier's switch
-- ---------------------------------------------------------------------------
clearLogs()
set(MOD, '{"server":true}')
check(denied(MOD), 'a moderator is refused, and told why')
set(DRIVER, '{"server":true,"admins":true}')
RM_onRequestState(ADMIN)
s = targeted[ADMIN].resultsSave
check(s.server == false and s.admins == false, 'neither a moderator nor a driver changed anything')
set(ADMIN, '{"server":"yes","admins":1}')
RM_onRequestState(ADMIN)
s = targeted[ADMIN].resultsSave
check(s.server == false and s.admins == false, 'only true and false are taken')

-- ---------------------------------------------------------------------------
-- 3. On admins' PCs only
-- ---------------------------------------------------------------------------
targeted = {}
set(ADMIN, '{"admins":true}')
check(targeted[ADMIN] and targeted[ADMIN].resultsSave.admins == true,
  'the admin who pressed it sees it on')
check(targeted[MOD] and targeted[MOD].resultsSave.admins == true,
  'and so does every other admin panel, without asking')
check(targeted[ADMIN].resultsSave.server == false, 'the other switch is left alone')
check((read(CONFIG) or ''):find('"copyResultsToAdmins"%s*:%s*true'), 'written to config.json')

clearLogs()
runRace()
local a, m = copiesTo(ADMIN), copiesTo(MOD)
check(#a == 1 and #m == 1 and #copiesTo(DRIVER) == 0,
  'one copy to each admin and moderator logged in, none to a driver')
check(a[1] and a[1].name:match(CLIENT_NAME), 'under a name the client keeps (' .. tostring(a[1] and a[1].name) .. ')')
check(a[1] and a[1].text:find('SESSION RESULTS', 1, true), 'holding the results')
check(#serverFiles() == 0 and announcedPath() == nil, 'and still no file on the server')
check(chatTo(ADMIN, UNSAVED) == nil, 'kept somewhere, so nobody is warned')

-- ---------------------------------------------------------------------------
-- 4. Restart from grid with no server file: the copy holds both races
-- ---------------------------------------------------------------------------
clearLogs()
go()
lap(DRIVER); lap(MOD)
RM_onRestartFromGrid(ADMIN)
check(lastState.phase == 'grid', 'the race is stopped and the field put back')
local stopped = copiesTo(ADMIN)[1]
check(stopped and stopped.text:find('Restarted from the grid by Admin', 1, true),
  'the stopped race goes to the admins, marked as restarted')

-- An hour on, so a name made now cannot be the stopped race's by chance.
dateShift = dateShift + 3600
clearLogs()
RM_onStartCountdown(ADMIN)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _ = 1, 2 do for _, p in ipairs({ DRIVER, MOD, ADMIN }) do lap(p) end end
seconds(6)
local rerun = copiesTo(ADMIN)[1]
check(rerun and stopped and rerun.name == stopped.name,
  'the rerun goes under the stopped race\'s name, so it replaces that copy')
check(rerun and count(rerun.text, 'SESSION RESULTS') == 2, 'with both races in it')
check(rerun and rerun.text:find('RESTART: the race above was stopped and run again', 1, true),
  'under the banner')
check(#serverFiles() == 0, 'and nothing on the server')

-- ---------------------------------------------------------------------------
-- 5. On the server only
-- ---------------------------------------------------------------------------
set(ADMIN, '{"server":true,"admins":false}')
clearLogs()
runRace()
local path = announcedPath()
check(path ~= nil, 'the chat line names the server\'s file')
check(read(path) and read(path):find('SESSION RESULTS', 1, true), 'and it is there')
check(#copiesTo(ADMIN) == 0 and #copiesTo(MOD) == 0, 'no copies sent')
removeTree(RESULTS_DIR)

-- ---------------------------------------------------------------------------
-- 6. Restart from grid, the server's file deleted before the rerun
-- ---------------------------------------------------------------------------
clearLogs()
go()
lap(DRIVER); lap(MOD)
RM_onRestartFromGrid(ADMIN)
local first = announcedPath()
check(first ~= nil, 'the stopped race is saved on the server')
os.remove(first)
clearLogs()
RM_onStartCountdown(ADMIN)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
for _ = 1, 2 do for _, p in ipairs({ DRIVER, MOD, ADMIN }) do lap(p) end end
seconds(6)
path = announcedPath()
local text = read(path) or ''
-- (It may take the same dated name again: the old one is free within a second.)
check(path ~= nil, 'the rerun is written to a new file')
check(count(text, 'SESSION RESULTS') == 2 and text:find('RESTART:', 1, true),
  'and the stopped race is in it too, not lost with the file')
removeTree(RESULTS_DIR)

-- ---------------------------------------------------------------------------
-- 7. Both, and they survive a restart of the server
-- ---------------------------------------------------------------------------
set(ADMIN, '{"admins":true}')
boot()
targeted = {}
RM_onRequestState(ADMIN)
s = targeted[ADMIN] and targeted[ADMIN].resultsSave
check(s and s.server == true and s.admins == true, 'both still on after a restart')
RM_onSetRaceLimits(ADMIN, '{"laps":2,"seconds":0,"mode":"laps"}')
RM_onSetFinishRule(ADMIN, '{"after":1,"seconds":0}')
clearLogs()
runRace()
path = announcedPath()
a = copiesTo(ADMIN)
check(path ~= nil and #a == 1, 'a file on the server and a copy to the admin')
check(a[1] and path and path:sub(-#a[1].name) == a[1].name, 'under the same name')
check(a[1] and a[1].text == read(path), 'with the same text')
removeTree(RESULTS_DIR)

-- ---------------------------------------------------------------------------
-- 8. A derby goes where a race does
-- ---------------------------------------------------------------------------
for _, xy in ipairs({ '0,0', '100,0', '100,100', '0,100' }) do
  local x, y = xy:match('(%d+),(%d+)')
  RM_onDerbyAddMarker(ADMIN, '{"x":' .. x .. ',"y":' .. y .. ',"z":50}')
end
local function runDerby()
  RM_onDerbyFormUp(ADMIN)
  RM_onDerbyStart(ADMIN)
  for _ = 1, 3 do RM_DerbyCountdownTick() end
  check(lastDerby and lastDerby.derbyPhase == 'running', 'the derby runs')
  RM_onDerbyEnd(ADMIN)
  check(lastDerby.derbyPhase == 'finished', 'and is ended')
end

set(ADMIN, '{"server":false,"admins":false}')
clearLogs()
runDerby()
check(#serverFiles() == 0 and #copiesTo(ADMIN) == 0, 'switched off, a derby keeps nothing')
check(chatTo(-1, 'Demo derby over') and not chatTo(-1, 'Results saved'),
  'its chat line says it is over, and nothing about a file')
check(chatTo(ADMIN, UNSAVED), 'and the admins are told')
RM_onDerbyEnd(ADMIN)

set(ADMIN, '{"server":true,"admins":true}')
clearLogs()
runDerby()
path = announcedPath()
a = copiesTo(ADMIN)
check(path and path:find('derby_results_', 1, true), 'on the server as derby_results_*.txt')
check(a[1] and a[1].name:match('^derby_results_') and a[1].name:match(CLIENT_NAME),
  'and to the admins under the same kind of name')
check(a[1] and a[1].text:find('DEMO DERBY RESULTS', 1, true) and a[1].text == read(path),
  'the same derby results both places')
RM_onDerbyEnd(ADMIN)
removeTree(RESULTS_DIR)

-- ---------------------------------------------------------------------------
-- 9. A drag tournament too, with its results built in full
-- ---------------------------------------------------------------------------
-- A two-gate point-to-point strip, two lanes, everyone connected entered.
local cps, starts = {}, {}
for i = 1, 2 do cps[i] = string.format('{"x":%d,"y":0,"z":0,"hx":0,"hy":1}', i * 400) end
for i = 1, 4 do starts[i] = string.format('{"x":0,"y":%d,"z":0,"hx":0,"hy":1}', i * 4) end
RM_onSaveLayout(ADMIN, '{"name":"Strip","width":20,"height":8,"depth":2,'
  .. '"pointToPoint":true,"confirmDrop":true,'
  .. '"checkpoints":[' .. table.concat(cps, ',') .. '],'
  .. '"startPositions":[' .. table.concat(starts, ',') .. ']}')
RM_onLoadLayout(ADMIN, '{"name":"Strip"}')
RM_onDragSetConfig(ADMIN, '{"format":"single","lanes":2,"advance":1,"seed":"order",'
  .. '"tree":"pro","holdResult":0,"timeout":30,"stageMode":"hold"}')
RM_onDragBuild(ADMIN, '')
check(lastDrag and lastDrag.entrants and #lastDrag.entrants == 3, 'three entrants on the ladder')
local pidOf = {}
for _, e in ipairs(lastDrag.entrants or {}) do
  for pid, name in pairs(connected) do if name == e.name then pidOf[e.seed] = pid end end
end
clearLogs()
for _ = 1, 10 do
  if lastDrag.dragPhase == 'complete' then break end
  RM_onDragStage(ADMIN)
  local lanes = {}
  for i, l in ipairs(lastDrag.current.lanes) do lanes[i] = l end
  RM_onDragRun(ADMIN)
  for _ = 1, 24 do if lastDrag.dragPhase ~= 'tree' then break end; RM_DragTick() end
  for i, l in ipairs(lanes) do
    RM_onDragResult(pidOf[l.seed], string.format('{"rt":%.3f,"et":%.3f,"speed":%d}',
      0.1 + i * 0.01, 10 + i * 0.1, 130 - i))
  end
  for _ = 1, 60 do if lastDrag.dragPhase ~= 'result' then break end; RM_DragTick() end
end
check(lastDrag.dragPhase == 'complete' and lastDrag.champion, 'the tournament is decided')
path = announcedPath()
a = copiesTo(ADMIN)
text = read(path) or ''
check(path and path:find('drag_results_', 1, true), 'on the server as drag_results_*.txt')
check(text:find('RACE MANAGER - DRAG TOURNAMENT', 1, true) and text:find('FINAL ORDER', 1, true)
  and text:find('THE LADDER', 1, true), 'with every section of the drag results')
check(text:find('WINNER      : ' .. tostring(lastDrag.champion), 1, true), 'naming the winner')
check(a[1] and a[1].name:match('^drag_results_') and a[1].text == text,
  'and the same text to the admins')
check(chatTo(-1, 'DRAG TOURNAMENT WINNER') and chatTo(-1, 'Results saved'),
  'the chat line names the winner and the file')

removeTree('Resources')

if fails == 0 then
  print(string.format('results_save_test: %d checks, 0 failures', checks))
else
  print(string.format('results_save_test: %d FAILURES of %d checks', fails, checks))
  os.exit(1)
end
