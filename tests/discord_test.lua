-- Headless test for the DISCORD add-on (server/RaceManager/discord.lua), run
-- against the real server plugin. Run from the repo root: lua5.3 tests/discord_test.lua
--
-- Sessions are driven through the real handlers. Nothing reaches the network
-- or starts a process: discord.sys stands in for os.execute, and a post is
-- answered by writing the files its curl would have left.

local connected = { [0] = 'Guest_A', [1] = 'Guest_B', [2] = 'Guest_C', [3] = 'Guest_D' }
local chat = {}          -- { target, msg }
local sent = {}          -- every TriggerClientEvent, { target, event, payload }
local printed = {}

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (target, msg) chat[#chat + 1] = { target = target, msg = msg } end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    sent[#sent + 1] = { target = target, event = event, payload = payload }
  end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
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

local realPrint = print
print = function (...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  printed[#printed + 1] = table.concat(parts, ' ')
end

local DATA = 'Resources/Server/RaceManager/Data'
local CFG_FILE = DATA .. '/discord.json'
local JOB = DATA .. '/discord'
os.remove(CFG_FILE)

dofile('server/RaceManager/main.lua')
local discord = require('discord')
local host = discord.host

local commands = {}
discord.sys.execute = function (cmd) commands[#commands + 1] = cmd; return true end

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; realPrint('FAIL: ' .. msg) end
end

local function read(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end
local function write(p, s)
  local f = assert(io.open(p, 'wb'))
  f:write(s)
  f:close()
end

local function said(needle, target)
  for _, c in ipairs(chat) do
    if (target == nil or c.target == target) and c.msg:find(needle, 1, true) then return true end
  end
  return false
end
local function lastState(target)
  for i = #sent, 1, -1 do
    local s = sent[i]
    if s.event == 'RM_Update' and s.target == target then return s.payload end
  end
end
local function lastNotice(target)
  for i = #sent, 1, -1 do
    local s = sent[i]
    if s.event == 'RM_Notice' and s.target == target then return s.payload.sub end
  end
end

local TOKEN = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-tokenTOKENtoken'
local HOOK = 'https://discord.com/api/webhooks/112233445566778899/' .. TOKEN

-- A post curl has sent: the files its script would have left.
local function answer(exit, http, body)
  write(JOB .. '/post.code', http or '')
  write(JOB .. '/post.resp', body or '')
  write(JOB .. '/post.done', tostring(exit) .. '\n')
  RM_DiscordTick()
end

local function lap(pid, t) RM_onLap(pid, '{"lapTime":' .. t .. '}') end

local function startQuali()
  RM_onSetQualiLimits(0, '{"laps":0,"seconds":0}')
  RM_onStartQualifying(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

local function startRace()
  RM_onGenerateGrid(0)
  RM_onStartCountdown(0)
  RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
end

-- Two home, one a lap down, one retired.
local function runRace()
  startRace()
  lap(0, 60); lap(1, 61); lap(2, 62); lap(3, 63)
  lap(0, 84.25); lap(1, 83.5)
  RM_onRetire(3)
  RM_onEndRace(0)
end

onInit()
RM_onLogin(0, '{"password":"phoenix"}'); RM_onSetReadyCheck(0, '{"on":false}')
RM_onChangePassword(0, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(3, '{"password":"tuesday"}')
for pid in pairs(connected) do RM_onPlayerJoin(pid) end
RM_onSetTotalLaps(0, '{"laps":2}')
RM_onSaveLayout(0, '{"name":"Club","width":20,"checkpoints":['
  .. '{"x":0,"y":0,"z":0,"hx":0,"hy":1},{"x":100,"y":0,"z":0,"hx":1,"hy":0}]}')
RM_onLoadLayout(0, '{"name":"Club"}')

-- ---------------------------------------------------------------------------
-- 1. Nothing global at file scope
-- ---------------------------------------------------------------------------
do
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile('server/RaceManager/discord.lua', 't', env))
  chunk()
  local leaked = {}
  for k in pairs(env) do leaked[#leaked + 1] = k end
  check(#leaked == 0, 'discord.lua defines no globals when BeamMP runs it on its own (found: '
    .. table.concat(leaked, ', ') .. ')')
  check(type(RM_onDiscordSet) == 'function' and type(RM_DiscordTick) == 'function',
    'and main.lua installed the handlers through init')
end

-- ---------------------------------------------------------------------------
-- 2. The webhook URL
-- ---------------------------------------------------------------------------
check(discord.checkWebhook(HOOK) == HOOK, 'a copied webhook URL is accepted as it is')
check(discord.checkWebhook('  ' .. HOOK .. '\n') == HOOK, 'pasted with spaces round it')
check(discord.checkWebhook('https://discordapp.com/api/webhooks/1/' .. TOKEN)
    and discord.checkWebhook('https://canary.discord.com/api/webhooks/1/' .. TOKEN)
    and discord.checkWebhook('https://ptb.discord.com/api/v10/webhooks/1/' .. TOKEN),
  'the other Discord hosts, and a versioned API path')
check(discord.checkWebhook(HOOK .. '?thread_id=998877') == HOOK .. '?thread_id=998877',
  'a thread id is kept')
check(discord.checkWebhook('https://ptb.discord.com/api/v10/webhooks/1/' .. TOKEN)
  == 'https://ptb.discord.com/api/webhooks/1/' .. TOKEN, 'and the URL is rebuilt from its parts')
for _, bad in ipairs({
  'http://discord.com/api/webhooks/1/' .. TOKEN,
  'https://discord.com.evil.net/api/webhooks/1/' .. TOKEN,
  'https://evil.net/api/webhooks/1/' .. TOKEN,
  'https://discord.com/api/webhooks/abc/' .. TOKEN,
  'https://discord.com/api/webhooks/1/short',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. '/extra',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. '?wait=true',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. '"&calc',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. ' $(reboot)',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. '\nurl = "http://x"',
  'https://discord.com/api/webhooks/1/' .. TOKEN .. '?thread_id=1;x',
  '', 42,
}) do
  check(discord.checkWebhook(bad) == nil, 'refused: ' .. tostring(bad):gsub('\n', '\\n'))
end
check(discord.hint(HOOK) == '\u{2026}8899' and not discord.hint(HOOK):find(TOKEN, 1, true),
  'the hint is the end of the id, never the token')

-- ---------------------------------------------------------------------------
-- 3. Off until a webhook is set
-- ---------------------------------------------------------------------------
RM_onRequestState(0)
local st = lastState(0).prmDiscord
check(st and st.configured == false and st.canEdit == true, 'an admin sees the row, not configured')
check(st.post.race == true and st.post.quali == false and st.post.derby and st.post.drag
  and st.attach == true, 'races, derbies and drag on, qualifying off, file attached')
RM_onRequestState(1)
check(lastState(1).prmDiscord == nil, 'a driver who is not an admin is sent nothing about it')

runRace()
check(#discord.queue == 0 and discord.job == nil, 'with no webhook a race queues nothing')
RM_DiscordTick()
check(#commands == 0, 'and nothing is started')

-- ---------------------------------------------------------------------------
-- 4. Setting the webhook: the admin tier's
-- ---------------------------------------------------------------------------
RM_onDiscordSet(3, '{"webhook":"' .. HOOK .. '"}')
check(read(CFG_FILE) == nil, 'a moderator cannot set it')
RM_onDiscordSet(1, '{"webhook":"' .. HOOK .. '"}')
check(read(CFG_FILE) == nil, 'nor a driver')
RM_onDiscordSet(0, '{"webhook":"https://example.com/hook"}')
check(read(CFG_FILE) == nil and (lastNotice(0) or ''):find('not a Discord webhook', 1, true),
  'something else is refused, and the admin is told why')
RM_onDiscordSet(0, '{"webhook":"' .. HOOK .. '"}')
local saved = host.jsonParse(read(CFG_FILE) or '{}')
check(saved.webhook == HOOK and saved.post.race == true and saved.attach == true,
  'saved to Data/discord.json with the defaults')
st = lastState(0).prmDiscord
check(st.configured and st.hint == '\u{2026}8899', 'the panel shows it set')
st = lastState(3).prmDiscord
check(st and st.configured and st.canEdit == false, 'a moderator sees it, and cannot change it')

-- ---------------------------------------------------------------------------
-- 5. A race posts its results
-- ---------------------------------------------------------------------------
connected[2] = 'Bob *the* `Hammer` @everyone'
RM_onPlayerJoin(2)
runRace()
check(#discord.queue == 1 and #commands == 0, 'the post is queued, not sent inside finishSession')
RM_DiscordTick()
check(discord.job ~= nil and #commands == 1, 'the tick starts curl')
local cmd = commands[1] or ''
check(not cmd:find(TOKEN, 1, true), 'the token is not on the command line')
local cfgText = read(JOB .. '/post.cfg') or ''
check(cfgText == 'url = "' .. HOOK .. '"\n', 'curl reads the URL from its config file')
local script = read(JOB .. '/post.cmd') or read(JOB .. '/post.sh') or ''
check(script:find('-K post.cfg', 1, true) and not script:find(TOKEN, 1, true),
  'the script names the config file, not the URL')
check(script:find('payload_json=<payload.json', 1, true) and script:find('files[0]=@results_', 1, true),
  'the payload and the results file go as form fields')

local body = host.jsonParse(read(JOB .. '/payload.json') or '{}')
local e = body.embeds and body.embeds[1] or {}
check(e.title == 'Race results', 'titled Race results')
check(type(body.allowed_mentions) == 'table' and #body.allowed_mentions.parse == 0
  and (read(JOB .. '/payload.json') or ''):find('"parse": []', 1, true),
  'no name can ping anybody')
check(body.attachments and body.attachments[1].id == 0
  and body.attachments[1].filename:match('^results_.*%.txt$'), 'the results file is attached')
local attached = body.attachments and read(JOB .. '/' .. body.attachments[1].filename) or ''
check(attached:find('SESSION RESULTS', 1, true), 'and it is the results file')
local desc = e.description or ''
check(desc:find('**Club** on', 1, true) and desc:find('2 laps', 1, true)
  and desc:find('4 drivers', 1, true), 'the track, the distance and the field')
check(desc:find('\nP1   Guest_A', 1, true) and desc:find('\nP2   Guest_B', 1, true),
  'the finishing order in a table')
check(desc:find('+1 lap', 1, true), 'a car a lap down says so')
check(desc:find('DNF  Guest_D', 1, true), 'a retirement is a DNF')
local block = desc:match('```\n(.-)\n```') or ''
check(not block:find('`', 1, true) and block:find("Bob *the* 'Hammer\u{2026}", 1, true),
  'a backtick in a name cannot end the table, and a long name is cut to its column')
local fields = {}
for _, f in ipairs(e.fields or {}) do fields[f.name] = f.value end
check(fields.Winner == 'Guest\\_A', 'the winner, markdown escaped')
check(fields['Fastest lap'] == 'Guest\\_B 1:23.500', 'the fastest lap')
check(e.footer and e.footer.text:find('^Every driver is home or out')
  or e.footer.text:find('^Ended by Guest_A'), 'why it ended, in the footer')
check(e.timestamp and e.timestamp:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'), 'a timestamp')

st = lastState(0).prmDiscord
check(st.sending == true, 'the panel says it is sending')

-- Discord accepts it.
answer(0, '204', '')
check(discord.job == nil and discord.last and discord.last.ok and discord.last.what == 'race results',
  'a 204 is a post that landed')
check(read(JOB .. '/post.cfg') == nil and read(JOB .. '/payload.json') == nil,
  'and every file it wrote is gone, the URL first')
RM_DiscordTick()
check(#commands == 1, 'nothing more to send')

-- ---------------------------------------------------------------------------
-- 6. A deleted webhook: told, kept for Retry
-- ---------------------------------------------------------------------------
chat = {}
runRace()
RM_DiscordTick()
answer(0, '404', '{"message": "Unknown Webhook", "code": 10015}')
check(discord.last and not discord.last.ok and discord.last.error:find('no such webhook', 1, true),
  'a 404 says the webhook is gone')
check(said('Discord: the race results were not posted', 0) and said('were not posted', 3)
  and not said('were not posted', 1), 'the admins are told in chat, the drivers are not')
st = lastState(0).prmDiscord
check(st.canRetry == true and st.last.ok == false, 'the panel offers Retry')
RM_onDiscordRetry(1)
check(#discord.queue == 0, 'a driver cannot retry')
RM_onDiscordRetry(3)
check(#discord.queue == 1 and discord.failed == nil, 'a moderator can')
RM_DiscordTick()
answer(0, '200', '{"id":"1"}')
check(discord.last.ok and lastNotice(3) == 'Posted the race results to Discord.',
  'and whoever pressed it hears it went')

-- ---------------------------------------------------------------------------
-- 7. Slow down, and no connection: tried again, then given up
-- ---------------------------------------------------------------------------
runRace()
RM_DiscordTick()
answer(0, '429', '{"message": "You are being rate limited.", "retry_after": 2.5}')
local job = discord.queue[1]
check(job and job.tries == 1 and job.notBefore - os.time() >= 3 and job.notBefore - os.time() <= 4,
  'a 429 waits as long as Discord asked')
job.notBefore = 0
RM_DiscordTick()
answer(7, '000', '')
job = discord.queue[1]
check(job and job.tries == 2, 'could not connect: tried again')
job.notBefore = 0
RM_DiscordTick()
answer(6, '000', '')
check(#discord.queue == 0 and discord.last.error:find('could not look up discord.com', 1, true),
  'the third failure gives up and says why')
discord.failed = nil

-- Not worth trying twice.
runRace()
RM_DiscordTick()
answer(0, '400', '{"message": "Invalid Form Body", "code": 50035}')
check(#discord.queue == 0 and discord.last.error:find('Invalid Form Body', 1, true),
  'a refused post is not sent again, and Discord\'s reason is shown')
check(discord.postError(127, '', '') == 'curl is not installed on this server'
  and discord.postError(9009, '', ''):find('curl.exe is missing', 1, true),
  'no curl says so')
discord.failed = nil

-- ---------------------------------------------------------------------------
-- 8. What is posted
-- ---------------------------------------------------------------------------
RM_onDiscordSet(0, '{"post":{"race":false},"attach":false}')
saved = host.jsonParse(read(CFG_FILE) or '{}')
check(saved.post.race == false and saved.attach == false and saved.webhook == HOOK,
  'a toggle keeps the webhook')
runRace()
check(#discord.queue == 0, 'races off: nothing queued')

RM_onDiscordSet(0, '{"post":{"race":true,"quali":true}}')
startQuali()
lap(0, 70); lap(1, 70); lap(2, 70)
lap(0, 85.5); lap(1, 84.25)
RM_onEndRace(0)
check(#discord.queue == 1, 'qualifying on: it posts when it closes')
RM_DiscordTick()
body = host.jsonParse(read(JOB .. '/payload.json') or '{}')
e = body.embeds and body.embeds[1] or {}
check(e.title == 'Qualifying results' and body.attachments == nil, 'qualifying, nothing attached')
desc = e.description or ''
local p1 = desc:find('P1   Guest_B', 1, true)
local p2 = desc:find('P2   Guest_A', 1, true)
check(p1 and p2 and p1 < p2, 'ordered by best lap, not by starting slot')
check((e.fields or {})[1] and e.fields[1].name == 'Pole' and e.fields[1].value == 'Guest\\_B 1:24.250',
  'the pole')
answer(0, '204', '')

-- A race stopped to be run again is not a round, and posts nothing.
RM_onDiscordSet(0, '{"post":{"quali":false}}')
startRace()
lap(0, 60); lap(1, 61)
RM_onRestartFromGrid(0)
check(#discord.queue == 0, 'a race restarted from the grid posts nothing')
RM_onStartCountdown(0)
RM_CountdownTick(); RM_CountdownTick(); RM_CountdownTick()
RM_onEndRace(0)
check(#discord.queue == 1, 'its rerun does')
discord.queue = {}

-- ---------------------------------------------------------------------------
-- 9. Derby and drag, through their builders
-- ---------------------------------------------------------------------------
local players = host.players
local derby = discord.build.derby({
  list = {
    { name = 'Guest_C', status = 'winner' },
    { name = 'Guest_A', status = 'eliminated', reason = 'Out of bounds', elimTime = 95.2 },
  },
  duration = 130, winner = 'Guest_C', arena = 'Pit', reason = 'last man standing: Guest_C',
})
desc = derby.embed.description
check(derby.embed.title == 'Demo derby results' and desc:find('**Pit** on', 1, true)
  and desc:find('2:10', 1, true), 'a derby: the arena and how long it ran')
check(desc:find('P1   Guest_C            WINNER', 1, true)
  and desc:find('P2   Guest_A            Out of bounds    1:35', 1, true), 'who went out, and when')
check(derby.embed.fields[1].value == 'Guest\\_C', 'and the winner')

local drag = discord.build.drag({
  list = { { pos = 1, name = 'Guest_B', wins = 3, losses = 0, bestET = 9.8765, bestRT = 0.123 },
           { pos = 2, name = 'Guest_A', wins = 2, losses = 1, bestET = 10.1 } },
  champion = 'Guest_B', format = 'single', entrants = 2,
})
desc = drag.embed.description
check(drag.embed.title == 'Drag tournament results' and desc:find('Single elimination', 1, true)
  and desc:find('2 entrants', 1, true), 'a drag tournament: the format and the field')
check(desc:find('P1   Guest_B            3-0   9.877    0.123', 1, true)
  and desc:find('P2   Guest_A            2-1   10.100   -', 1, true), 'records and best times')

check(discord.build.derby({ list = {} }) == nil and discord.build.drag({}) == nil,
  'nothing to post when nobody took part')

-- Long fields stop at M.ROWS and say where the rest are.
local long = {}
for i = 1, 25 do long[i] = { pos = i, name = 'Driver' .. i, wins = 0, losses = 1 } end
desc = discord.build.drag({ list = long, format = 'points', file = 'x.txt' }).embed.description
check(desc:find('Driver20', 1, true) and not desc:find('Driver21', 1, true)
  and desc:find('and 5 more in the results file attached', 1, true), 'twenty rows, then a note')

-- A fault in a builder never reaches the session.
local realBuild = discord.build.race
discord.build.race = function () error('boom') end
local ok = pcall(host.race.discordPost, 'race', {})
discord.build.race = realBuild
check(ok and printed[#printed]:find('Discord post failed: ', 1, true), 'a builder fault is caught')

-- ---------------------------------------------------------------------------
-- 10. A test message, and removing the webhook
-- ---------------------------------------------------------------------------
RM_onDiscordTest(3)
check(#discord.queue == 0, 'a moderator cannot send a test')
RM_onDiscordTest(0)
RM_DiscordTick()
body = host.jsonParse(read(JOB .. '/payload.json') or '{}')
check(body.embeds and body.embeds[1].title == 'Phoenix Race Manager is connected'
  and body.embeds[1].description:find('races, derbies, drag tournaments', 1, true),
  'the test says what will be posted')
answer(0, '401', '{"message": "Invalid Webhook Token"}')
check(lastNotice(0) and lastNotice(0):find('webhook token', 1, true) and discord.failed == nil,
  'a failed test is told to whoever sent it, and is not kept for Retry')

runRace()
check(#discord.queue == 1, 'a post is waiting')
RM_onDiscordSet(0, '{"clear":true}')
saved = host.jsonParse(read(CFG_FILE) or '{}')
check(saved.webhook == '' and saved.post.race == true, 'removed, the toggles kept')
RM_DiscordTick()
check(#discord.queue == 0 and discord.job == nil, 'and the waiting post is dropped, not sent')
st = lastState(0).prmDiscord
check(st.configured == false, 'the panel says it is off')

-- ---------------------------------------------------------------------------
-- 11. A hand-edited file that does not parse
-- ---------------------------------------------------------------------------
write(CFG_FILE, '{"webhook": "' .. HOOK .. '", oops')
runRace()
check(#discord.queue == 0, 'nothing is posted')
RM_onDiscordSet(0, '{"webhook":"' .. HOOK .. '"}')
check(read(CFG_FILE) == '{"webhook": "' .. HOOK .. '", oops', 'and the file is not written over')
RM_onRequestState(0)
check(lastState(0).prmDiscord.error ~= nil, 'the panel says why')

-- Leftovers from a post cut off by a restart are cleared at boot.
write(JOB .. '/post.cfg', 'url = "' .. HOOK .. '"\n')
discord.warm()
check(read(JOB .. '/post.cfg') == nil, 'warm clears what a post left behind')

-- ---------------------------------------------------------------------------
-- 12. The token never left the server
-- ---------------------------------------------------------------------------
local leaks = 0
for _, s in ipairs(sent) do
  local text = type(s.payload) == 'table' and host.jsonStringify(s.payload) or tostring(s.payload)
  if text:find(TOKEN, 1, true) then leaks = leaks + 1 end
end
for _, c in ipairs(chat) do if c.msg:find(TOKEN, 1, true) then leaks = leaks + 1 end end
for _, l in ipairs(printed) do if l:find(TOKEN, 1, true) then leaks = leaks + 1 end end
check(leaks == 0, 'the webhook token is in no client event, chat line or log line (found ' .. leaks .. ')')

os.remove(CFG_FILE)
print = realPrint
if fails == 0 then
  print('discord_test: ' .. checks .. ' checks, 0 failures')
else
  print('discord_test: ' .. fails .. ' FAILURES of ' .. checks .. ' checks')
  os.exit(1)
end
