-- Race Manager: DISCORD, an optional add-on that posts results to a channel
-- through a webhook.
--
-- OFF UNTIL A WEBHOOK IS SET, from the Admin tab or in Data/discord.json. With
-- none, nothing here starts a process or touches the network. Deleting this
-- file turns it off as well: main.lua loads it with pcall and nothing else
-- depends on it.
--
-- NOTHING GLOBAL AT FILE SCOPE. BeamMP runs every .lua in the plugin folder on
-- its own too, so the RM_Discord* handlers are installed by init().
--
-- THE WEBHOOK URL IS A SECRET: whoever holds it can post to the channel. It is
-- never sent to a client and never printed; the panel sees the last digits of
-- the webhook id. Only a URL that passes checkWebhook is stored, so nothing an
-- admin types reaches a shell, and curl reads it from a config file rather than
-- its command line, where any user on a Linux host could read it.
--
-- BeamMP has no HTTP client, so a post is curl in a process of its own that
-- leaves a .done file, polled once a second (update.lua downloads the same
-- way). A post is BUILT when the session ends, so it is a snapshot, and SENT
-- from the tick, one at a time.

local M = {}
local host

local IS_WINDOWS = package.config:sub(1, 1) == '\\'

M.FILE        = 'discord.json'
M.SECONDS     = 30          -- curl's limit for one post
M.MAX_QUEUE   = 10
M.TRIES       = 3           -- for a post Discord asked to slow down, or that never connected
M.WAIT        = { 10, 30 }  -- seconds before the second and third try
M.ROWS        = 20          -- table rows in a post; the attached file has the rest
M.MAX_ATTACH  = 1024 * 1024

-- Relative to the server's working directory. Tests point these at scratch.
M.paths = { root = '', data = 'Resources/Server/RaceManager/Data' }

-- Process calls, as a table so the tests can stand in for them.
M.sys = { popen = io.popen, execute = os.execute }

M.KINDS = { 'race', 'quali', 'derby', 'drag' }
local DEFAULT_POST = { race = true, quali = false, derby = true, drag = true }

local COLOR = { race = 0xF39C12, quali = 0x3498DB, derby = 0xE74C3C, drag = 0x2ECC71,
                test = 0x95A5A6 }

M.queue  = {}
M.job    = nil   -- the post curl is sending
M.last   = nil   -- { ok, what, at, error }: the last post that finished
M.failed = nil   -- the last post that gave up, for Retry
M.build  = {}

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------
local function at(p)
  if M.paths.root == '' or p:match('^%a:') or p:sub(1, 1) == '/' then return p end
  return M.paths.root .. '/' .. p
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function writeFile(path, data)
  local f = io.open(path, 'wb')
  if not f then return false end
  local ok = f:write(data)
  f:close()
  return ok ~= nil and readFile(path) == data
end

local function cfgPath() return M.paths.data .. '/' .. M.FILE end
local function jobDir() return M.paths.data .. '/discord' end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------
-- Printable, valid UTF-8, at most `max` characters. A driver's name is their
-- own typing, and Discord refuses a post with a broken byte in it.
local function clean(s, max)
  s = tostring(s or ''):gsub('[%z\1-\31\127]', ' ')
  if not utf8.len(s) then s = s:gsub('[\128-\255]', '?') end
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  if max and utf8.len(s) > max then
    s = s:sub(1, utf8.offset(s, max) - 1) .. '\u{2026}'
  end
  return s
end
M.clean = clean

-- Outside a code block: a name like *Bob* or [x](y) stays a name.
local function md(s, max)
  return (clean(s, max):gsub('[\\%*_~|`>%[%]%(%)#%-<:]', '\\%0'))
end

-- Inside one only a backtick can break out.
local function code(s, max) return (clean(s, max):gsub('`', "'")) end

-- Widths count characters, not bytes, or an accented name pushes its row out.
local function padTo(s, w)
  local n = utf8.len(s) or #s
  return n < w and (s .. string.rep(' ', w - n)) or s
end

local function grid(head, rows, widths)
  local function line(cells)
    local out = {}
    for i = 1, #widths do
      local s = code(cells[i] or '', widths[i])
      out[i] = i < #widths and padTo(s, widths[i]) or s
    end
    return (table.concat(out, ' '):gsub('%s+$', ''))
  end
  local lines = { line(head) }
  for i = 1, math.min(#rows, M.ROWS) do lines[#lines + 1] = line(rows[i]) end
  return '```\n' .. table.concat(lines, '\n') .. '\n```'
end

local function capital(s)
  s = clean(s, 200)
  return (s:gsub('^%l', string.upper))
end

local function mmss(t)
  t = tonumber(t)
  if not t then return '-' end
  local m = math.floor(t / 60)
  return string.format('%d:%02d', m, math.floor(t - m * 60))
end

local function secs(t)
  t = tonumber(t)
  return t and string.format('%.3f', t) or '-'
end

local function lap(t) return t and host.fmtLap(t) or '-' end

-- ---------------------------------------------------------------------------
-- The webhook
-- ---------------------------------------------------------------------------
local HOSTS = { ['discord.com'] = true, ['discordapp.com'] = true,
                ['ptb.discord.com'] = true, ['canary.discord.com'] = true }

-- The URL rebuilt from its checked parts, or nil. Copy Webhook URL gives
-- https://discord.com/api/webhooks/<id>/<token>; ?thread_id= posts into a
-- forum post or thread.
function M.checkWebhook(url)
  if type(url) ~= 'string' or #url > 300 then return nil end
  url = url:gsub('^%s+', ''):gsub('%s+$', '')
  local site, ver, id, token, rest =
    url:match('^https://([%w%.]+)/api/(v?%d*/?)webhooks/(%d+)/([%w_%-]+)(.*)$')
  if not site or not HOSTS[site:lower()] then return nil end
  if ver ~= '' and not ver:match('^v%d+/$') then return nil end
  if #id > 25 or #token < 20 or #token > 100 then return nil end
  local thread = rest:match('^%?thread_id=(%d+)$')
  if rest ~= '' and not (thread and #thread <= 25) then return nil end
  return 'https://' .. site:lower() .. '/api/webhooks/' .. id .. '/' .. token
    .. (thread and ('?thread_id=' .. thread) or '')
end

-- What the panel and the log show: the last digits of the id, never the token.
function M.hint(url)
  local id = type(url) == 'string' and url:match('/webhooks/(%d+)/')
  return id and ('\u{2026}' .. id:sub(-4)) or nil
end

-- ---------------------------------------------------------------------------
-- Settings: Data/discord.json, read on every use so a hand edit applies to
-- the next post. A file that does not parse posts nothing and is never
-- written over.
-- ---------------------------------------------------------------------------
local warnedText = nil

function M.config()
  local cfg = { post = {}, attach = true }
  for k, v in pairs(DEFAULT_POST) do cfg.post[k] = v end
  local text = readFile(at(cfgPath()))
  if not text then return cfg, true end
  local ok, data = pcall(host.jsonParse, text)
  if not ok or type(data) ~= 'table' then
    if warnedText ~= text then
      warnedText = text
      print('[RaceManager] Could not parse ' .. cfgPath() .. ': nothing is posted to Discord '
        .. 'until it is fixed. It is left exactly as it is.')
    end
    return cfg, false
  end
  if type(data.webhook) == 'string' and data.webhook ~= '' then
    cfg.webhook = M.checkWebhook(data.webhook)
    if not cfg.webhook and warnedText ~= text then
      warnedText = text
      print('[RaceManager] The webhook in ' .. cfgPath() .. ' is not a Discord webhook URL, '
        .. 'so nothing is posted to Discord')
    end
  end
  for _, k in ipairs(M.KINDS) do
    if type(data.post) == 'table' and type(data.post[k]) == 'boolean' then
      cfg.post[k] = data.post[k]
    end
  end
  if type(data.attach) == 'boolean' then cfg.attach = data.attach end
  return cfg, true
end

local function save(cfg)
  host.makeDirectory(at(M.paths.data))
  local status = host.writeFile(at(cfgPath()), host.jsonStringify({
    webhook = cfg.webhook or '', post = cfg.post, attach = cfg.attach }))
  return status ~= nil and status ~= false
end

-- ---------------------------------------------------------------------------
-- Posts. Each builder returns { what, embed, file } or nil for nothing to say.
-- ---------------------------------------------------------------------------
local function serverName()
  if not (MP.Settings and MP.Settings.Name ~= nil) then return nil end
  local ok, name = pcall(MP.Get, MP.Settings.Name)
  if not ok or type(name) ~= 'string' then return nil end
  name = clean(name:gsub('%^%w', ''), 60)
  return name ~= '' and name or nil
end

local function footer(note)
  local parts = {}
  if note and note ~= '' then parts[#parts + 1] = capital(note) end
  local name = serverName()
  if name then parts[#parts + 1] = name end
  parts[#parts + 1] = 'Phoenix Race Manager v' .. tostring(host.RM_BUILD)
  return { text = clean(table.concat(parts, ' \u{00B7} '), 2000) }
end

-- Each line is cleaned as it is built; clean() here would take the newlines.
local function embed(kind, title, lines, fields, note)
  local text = table.concat(lines, '\n')
  if (utf8.len(text) or 0) > 4000 then text = text:sub(1, utf8.offset(text, 3990) - 1) .. '\n```' end
  return {
    title = clean(title, 250), color = COLOR[kind], description = text,
    fields = fields or {}, footer = footer(note),
    timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
end

local function addField(fields, name, value)
  if value and value ~= '' then
    fields[#fields + 1] = { name = name, value = clean(value, 1000), inline = true }
  end
end

local function trackName()
  local layout = host.race.layout
  return type(layout) == 'table' and type(layout.name) == 'string' and layout.name or nil
end

local function where(name)
  local map = host.mapLabel(host.getCurrentMap())
  return name and ('**' .. md(name, 60) .. '** on ' .. md(map, 60)) or ('On ' .. md(map, 60))
end

-- The rows past M.ROWS are in the file, attached or on the server.
local function more(rows, file)
  local extra = #rows - M.ROWS
  if extra <= 0 then return nil end
  return string.format('and %d more in the results %s', extra,
    file and 'file attached' or 'file on the server')
end

local function sessionTitle(base)
  local r = host.race
  if (r.heatCount or 0) > 0 then
    if (r.heatCurrent or 0) > 0 then return 'Heat ' .. r.heatCurrent .. ' results' end
    return 'Feature results'
  end
  return base
end

function M.build.race(data)
  local final = host.raceClassification()
  if #final == 0 then return nil end
  local r = host.race
  local pace = r.racePaceLapRun and 1 or 0
  local function lapsRun(rec)
    local n = host.lapsDone(rec) - pace
    return n > 0 and n or 0
  end
  local leaderLaps = 0
  for _, rec in ipairs(final) do leaderLaps = math.max(leaderLaps, lapsRun(rec)) end

  local winner = final[1].finishTime and final[1].status ~= 'dsq' and final[1] or nil
  local rows = {}
  for i, rec in ipairs(final) do
    local pos, time
    if rec.status == 'dsq' then
      pos, time = 'DSQ', 'DSQ'
    elseif rec.finishTime then
      pos = 'P' .. i
      local down = leaderLaps - lapsRun(rec)
      if down > 0 then
        time = '+' .. down .. (down == 1 and ' lap' or ' laps')
      elseif winner and rec ~= winner then
        local gap = rec.finishTime - winner.finishTime
        time = '+' .. (gap >= 60 and host.fmtLap(gap) or string.format('%.3f', gap))
      else
        time = host.fmtLap(rec.finishTime)
      end
    else
      pos, time = 'DNF', 'DNF'
    end
    rows[i] = { pos, host.displayName(rec), lap(rec.raceBest), time }
  end

  local lines = { string.format('%s \u{00B7} %s \u{00B7} %d driver%s', where(trackName()),
    host.raceLength(), #final, #final == 1 and '' or 's') }
  lines[#lines + 1] = grid({ 'Pos', 'Driver', 'Best', 'Time' }, rows, { 4, 18, 9, 10 })
  lines[#lines + 1] = more(rows, data.file)

  local fields = {}
  local awards = host.sessionAwards(final)
  local players = host.players
  local fastest = awards.fastestLapPid and players[awards.fastestLapPid] or nil
  local pole = host.qualiClassification()[1]
  local hc = awards.hardChargerPid and players[awards.hardChargerPid] or nil
  addField(fields, 'Winner', winner and md(host.displayName(winner), 40))
  addField(fields, 'Fastest lap', fastest and awards.fastestLapTime
    and (md(host.displayName(fastest), 40) .. ' ' .. host.fmtLap(awards.fastestLapTime)))
  addField(fields, 'Pole', pole and pole.qualiBest
    and (md(host.displayName(pole), 40) .. ' ' .. host.fmtLap(pole.qualiBest)))
  addField(fields, 'Hard charger', hc and string.format('%s P%d \u{2192} P%d',
    md(host.displayName(hc), 40), awards.hardChargerFrom, awards.hardChargerTo))

  local title = sessionTitle('Race results')
  return { what = title:lower(), file = data.file,
    embed = embed('race', title, lines, fields, data.reason) }
end

-- By best lap, not qualiClassification: until Generate Grid, gridPos is the
-- slot each car STARTED qualifying from.
function M.build.quali(data)
  local list = {}
  for _, rec in pairs(host.players) do
    if rec.qualiBest or (rec.qualiLaps or 0) > 0 then list[#list + 1] = rec end
  end
  table.sort(list, function (a, b)
    if (a.qualiBest ~= nil) ~= (b.qualiBest ~= nil) then return a.qualiBest ~= nil end
    if a.qualiBest and a.qualiBest ~= b.qualiBest then return a.qualiBest < b.qualiBest end
    return (a.id or 0) < (b.id or 0)
  end)
  local rows = {}
  local pole = list[1] and list[1].qualiBest and list[1] or nil
  for i, rec in ipairs(list) do
    rows[i] = { 'P' .. i, host.displayName(rec), lap(rec.qualiBest), tostring(rec.qualiLaps or 0) }
  end
  if #rows == 0 then return nil end
  local lines = { string.format('%s \u{00B7} %d driver%s', where(trackName()),
    #rows, #rows == 1 and '' or 's') }
  lines[#lines + 1] = grid({ 'Pos', 'Driver', 'Best', 'Laps' }, rows, { 4, 18, 9, 4 })
  lines[#lines + 1] = more(rows, nil)
  local fields = {}
  addField(fields, 'Pole', pole and (md(host.displayName(pole), 40) .. ' ' .. lap(pole.qualiBest)))
  return { what = 'qualifying results',
    embed = embed('quali', 'Qualifying results', lines, fields, data.reason) }
end

function M.build.derby(data)
  local list = type(data.list) == 'table' and data.list or {}
  if #list == 0 then return nil end
  local rows = {}
  for i, rec in ipairs(list) do
    local result, out
    if rec.status == 'winner' then
      result, out = 'WINNER', 'survived'
    elseif rec.status == 'alive' then
      result, out = 'Running', '-'
    else
      result, out = rec.reason or 'Out', mmss(rec.elimTime)
    end
    rows[i] = { 'P' .. i, host.displayName(rec), result, out }
  end
  local lines = { string.format('%s \u{00B7} %s \u{00B7} %d driver%s',
    where(type(data.arena) == 'string' and data.arena or nil), mmss(data.duration),
    #list, #list == 1 and '' or 's') }
  lines[#lines + 1] = grid({ 'Pos', 'Driver', 'Result', 'Out at' }, rows, { 4, 18, 16, 8 })
  lines[#lines + 1] = more(rows, data.file)
  local fields = {}
  addField(fields, 'Winner', type(data.winner) == 'string' and md(data.winner, 40) or nil)
  return { what = 'derby results', file = data.file,
    embed = embed('derby', 'Demo derby results', lines, fields, data.reason) }
end

local DRAG_FORMAT = { single = 'Single elimination', double = 'Double elimination',
                      points = 'Points shootout' }

function M.build.drag(data)
  local list = type(data.list) == 'table' and data.list or {}
  if #list == 0 then return nil end
  local rows = {}
  for i, row in ipairs(list) do
    rows[i] = { 'P' .. (row.pos or i), row.name, (row.wins or 0) .. '-' .. (row.losses or 0),
      secs(row.bestET), secs(row.bestRT) }
  end
  local lines = { string.format('%s \u{00B7} %s \u{00B7} %d entrant%s', where(trackName()),
    DRAG_FORMAT[data.format] or clean(data.format, 30), tonumber(data.entrants) or #list,
    (tonumber(data.entrants) or #list) == 1 and '' or 's') }
  lines[#lines + 1] = grid({ 'Pos', 'Driver', 'W-L', 'Best ET', 'Best RT' }, rows,
    { 4, 18, 5, 8, 7 })
  lines[#lines + 1] = more(rows, data.file)
  local fields = {}
  addField(fields, 'Winner', type(data.champion) == 'string' and md(data.champion, 40) or nil)
  return { what = 'drag results', file = data.file,
    embed = embed('drag', 'Drag tournament results', lines, fields, data.reason) }
end

function M.build.test(data)
  local on = {}
  local names = { race = 'races', quali = 'qualifying', derby = 'derbies', drag = 'drag tournaments' }
  for _, k in ipairs(M.KINDS) do
    if data.post and data.post[k] then on[#on + 1] = names[k] end
  end
  local lines = { #on > 0
    and ('Results from this server are posted here: ' .. table.concat(on, ', ') .. '.')
    or 'Every kind of result is switched off, so nothing is posted yet.' }
  return { what = 'test message',
    embed = embed('test', 'Phoenix Race Manager is connected', lines, {}, data.who
      and ('Sent by ' .. data.who) or nil) }
end

-- The attachment, read now: a rerun appends to the same file later.
local function attachment(path)
  if type(path) ~= 'string' then return nil end
  local data = readFile(path)
  if not data or data == '' then return nil end
  if #data > M.MAX_ATTACH then
    print('[RaceManager] Discord: ' .. path .. ' is too large to attach, so the post goes without it')
    return nil
  end
  local name = (path:gsub(string.char(92), '/'):match('([^/]+)$') or 'results.txt')
    :gsub('[^%w%-_%.]', '_')
  if not name:match('%.txt$') then name = name .. '.txt' end
  return { name = name, data = data }
end

local function payload(built, file)
  local p = {
    embeds = { built.embed },
    -- A driver called @everyone pings nobody.
    allowed_mentions = { parse = {} },
  }
  if file then p.attachments = { { id = 0, filename = file.name } } end
  return host.jsonStringify(p)
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
local function push()
  if host and host.pushAdmins then pcall(host.pushAdmins) end
end

local function notice(pid, msg)
  if pid then
    MP.TriggerClientEvent(pid, 'RM_Notice', Util.JsonEncode({
      kind = 'session', msg = 'Discord', sub = msg }))
  end
end

local function shQuote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function psQuote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end
local function native(p) return IS_WINDOWS and (p:gsub('/', '\\')) or p end

-- The server's folder, asked once. A test's absolute root stands in for it.
function M.cwd()
  if M.cwdCache then return M.cwdCache end
  local root = M.paths.root
  if root:match('^%a:') or root:sub(1, 1) == '/' then
    M.cwdCache = root
    return root
  end
  local ok, pipe = pcall(M.sys.popen, IS_WINDOWS and 'cd' or 'pwd')
  if ok and pipe then
    local line = pipe:read('l')
    pipe:close()
    if type(line) == 'string' and line:match('%S') then
      M.cwdCache = (line:gsub('%s+$', ''):gsub([[\]], '/'))
    end
  end
  return M.cwdCache
end

local JOB_FILES = { 'post.cfg', 'payload.json', 'post.code', 'post.resp', 'post.err',
                    'post.done', 'post.cmd', 'post.sh' }

local function clearJob(job)
  local dir = jobDir()
  for _, name in ipairs(JOB_FILES) do os.remove(at(dir .. '/' .. name)) end
  if job and job.file then os.remove(at(dir .. '/' .. job.file.name)) end
end

-- Every file the script names is in its own folder, so no path is quoted into
-- a form field, and the URL is in post.cfg.
function M.jobScript(job)
  local ua = 'PhoenixRaceManager/' .. tostring(host and host.RM_BUILD or '0')
  local form = '-F "payload_json=<payload.json;type=application/json"'
    .. (job.file and (' -F "files[0]=@' .. job.file.name .. ';type=text/plain"') or '')
  if IS_WINDOWS then
    return table.concat({
      '@echo off',
      'rem Written by Race Manager to post to Discord. Safe to delete.',
      'cd /d "%~dp0"',
      '"%SystemRoot%\\System32\\curl.exe" -sS --connect-timeout 15 --max-time ' .. M.SECONDS
        .. ' -A "' .. ua .. '" -K post.cfg ' .. form
        .. ' -o post.resp -w "%%{http_code}" >post.code 2>post.err',
      '>post.done echo %errorlevel%',
      '',
    }, '\r\n')
  end
  return table.concat({
    '#!/bin/bash',
    '# Written by Race Manager to post to Discord. Safe to delete.',
    -- The server's sockets, closed: see the relaunch helper in maps.lua.
    'if [ -n "$BASH_VERSION" ]; then',
    '  for fd in /proc/$$/fd/*; do n=${fd##*/}',
    '    case $n in 0|1|2|255) ;; *) eval "exec $n>&-" ;; esac',
    '  done 2>/dev/null',
    'fi',
    'cd "$(dirname "$0")" || exit 1',
    'if ! command -v curl >/dev/null 2>&1; then echo 127 > post.done; exit 0; fi',
    'curl -sS --connect-timeout 15 --max-time ' .. M.SECONDS .. ' -A ' .. shQuote(ua)
      .. ' -K post.cfg ' .. form .. " -o post.resp -w '%{http_code}' >post.code 2>post.err",
    'echo $? > post.done',
    '',
  }, '\n')
end

-- On Windows through Start-Process, so curl holds none of the server's
-- sockets. That costs the server a moment while PowerShell starts, which is
-- why it happens on the tick after a session closes and not inside it.
function M.spawn(path, dir)
  local ok, res
  if IS_WINDOWS then
    ok, res = pcall(M.sys.execute, 'powershell -NoProfile -NonInteractive -Command "'
      .. 'Start-Process -FilePath ' .. psQuote(native(path))
      .. ' -WorkingDirectory ' .. psQuote(native(dir)) .. ' -WindowStyle Hidden"')
  else
    ok, res = pcall(M.sys.execute, '(command -v bash >/dev/null && nohup bash ' .. shQuote(path)
      .. ' || nohup sh ' .. shQuote(path) .. ') > /dev/null 2>&1 < /dev/null &')
  end
  return ok and res == true
end

local timerOn, timerOff

local function finish(job, ok, why)
  M.last = { ok = ok, what = job.what, at = os.time(), error = why }
  if ok then
    print('[RaceManager] Discord: posted the ' .. job.what)
    if M.failed == job then M.failed = nil end
    notice(job.notify, 'Posted the ' .. job.what .. ' to Discord.')
  else
    local were = job.what:find('results', 1, true) and ' were' or ' was'
    print('[RaceManager] Discord: the ' .. job.what .. were .. ' not posted: ' .. why)
    if job.kind ~= 'test' then
      M.failed = job
      if host.tellAdmins then
        host.tellAdmins('[RaceManager] Discord: the ' .. job.what .. were .. ' not posted ('
          .. why .. '). Retry is on the Admin tab.')
      end
    end
    notice(job.notify, 'Not posted: ' .. why .. '.')
  end
  push()
end

local function start(job, webhook)
  local cwd = M.cwd()
  if not cwd then return finish(job, false, 'could not tell which folder the server runs in') end
  local dir = jobDir()
  host.makeDirectory(at(dir))
  clearJob(job)
  local script = dir .. (IS_WINDOWS and '/post.cmd' or '/post.sh')
  local wrote = writeFile(at(dir .. '/post.cfg'), 'url = "' .. webhook .. '"\n')
    and writeFile(at(dir .. '/payload.json'), job.body)
    and (not job.file or writeFile(at(dir .. '/' .. job.file.name), job.file.data))
    and writeFile(at(script), M.jobScript(job))
  if not wrote then
    clearJob(job)
    return finish(job, false, 'could not write to ' .. dir)
  end
  local abs = at(script)
  if not (abs:match('^%a:') or abs:sub(1, 1) == '/') then abs = cwd .. '/' .. abs end
  if not M.spawn(abs, abs:match('^(.*)/[^/]+$')) then
    clearJob(job)
    return finish(job, false, 'could not start curl')
  end
  job.tries = (job.tries or 0) + 1
  job.started = os.time()
  M.job = job
end

local CURL = {
  [6]    = 'could not look up discord.com (is the server offline?)',
  [7]    = 'could not connect to Discord',
  [28]   = 'Discord took too long to answer',
  [35]   = 'the secure connection to Discord failed',
  [60]   = 'the secure connection to Discord failed (certificates)',
  [127]  = 'curl is not installed on this server',
  [9009] = 'curl.exe is missing (Windows 10 1803 and later include it)',
}
local AGAIN = { [6] = true, [7] = true, [28] = true, [35] = true, [52] = true, [55] = true,
                [56] = true }
local HTTP = {
  [400] = 'Discord refused the post',
  [401] = 'Discord refused the webhook token: set the webhook again',
  [403] = 'Discord refused the webhook: it may not post to that thread',
  [404] = 'Discord has no such webhook: it was deleted, or the URL is wrong',
  [413] = 'the post is too large for Discord',
  [429] = 'Discord asked for fewer posts',
}

-- nil for a post that landed, else why, whether trying again can help, and
-- how long Discord asked us to wait.
function M.postError(code, http, body)
  if code ~= 0 then
    return CURL[code] or ('curl failed (code ' .. tostring(code) .. ')'), AGAIN[code] == true
  end
  http = tonumber(http) or 0
  if http >= 200 and http < 300 then return nil end
  local msg = type(body) == 'string' and body:match('"message"%s*:%s*"([^"]*)"') or nil
  local why = (HTTP[http] or (http >= 500 and 'Discord is having trouble' or 'Discord refused the post'))
    .. ' (HTTP ' .. http .. ((msg and http ~= 404) and (': ' .. clean(msg, 120)) or '') .. ')'
  local wait = http == 429 and type(body) == 'string'
    and tonumber(body:match('"retry_after"%s*:%s*([%d%.]+)')) or nil
  return why, http == 429 or http >= 500 or http == 0, wait
end

local function poll()
  local job = M.job
  local dir = jobDir()
  local text = readFile(at(dir .. '/post.done'))
  local code = text and tonumber(text:match('%d+'))
  if not code then
    if os.time() - job.started <= M.SECONDS + 30 then return end
    M.job = nil
    clearJob(job)
    return finish(job, false, 'no answer from curl after ' .. (M.SECONDS + 30) .. ' seconds')
  end
  M.job = nil
  local http = readFile(at(dir .. '/post.code'))
  local body = readFile(at(dir .. '/post.resp'))
  clearJob(job)
  local why, again, wait = M.postError(code, http and http:match('%d+'), body)
  if not why then return finish(job, true) end
  if again and job.tries < M.TRIES then
    local delay = wait and math.min(math.ceil(wait) + 1, 120) or M.WAIT[job.tries] or 30
    job.notBefore = os.time() + delay
    table.insert(M.queue, 1, job)
    print('[RaceManager] Discord: ' .. why .. '; trying the ' .. job.what .. ' again in '
      .. delay .. 's')
    return push()
  end
  return finish(job, false, why)
end

function M.tick()
  if M.job then return poll() end
  local job = M.queue[1]
  if not job then return timerOff() end
  if os.time() < (job.notBefore or 0) then return end
  table.remove(M.queue, 1)
  local cfg = M.config()
  if not cfg.webhook then
    M.queue = {}
    print('[RaceManager] Discord: the webhook was removed, so the waiting posts were dropped')
    timerOff()
    return push()
  end
  start(job, cfg.webhook)
  push()
end

timerOn = function ()
  if M.ticking then return end
  M.ticking = true
  MP.CreateEventTimer('RM_DiscordTick', 1000)
end

timerOff = function ()
  if not M.ticking then return end
  M.ticking = false
  MP.CancelEventTimer('RM_DiscordTick')
end

function M.enqueue(job)
  if #M.queue >= M.MAX_QUEUE then
    print('[RaceManager] Discord: ' .. #M.queue .. ' posts are already waiting, so the '
      .. job.what .. ' are not posted')
    return false
  end
  job.tries, job.notBefore = 0, 0
  M.queue[#M.queue + 1] = job
  timerOn()
  push()
  return true
end

-- From main.lua, derby.lua and drag.lua as each session closes: `kind` is
-- race, quali, derby or drag; `data` what that kind's builder reads.
function M.post(kind, data)
  local cfg = M.config()
  if not cfg.webhook or not cfg.post[kind] then return false end
  local built = M.build[kind](data or {})
  if not built then return false end
  local file = cfg.attach and attachment(built.file) or nil
  return M.enqueue({ kind = kind, what = built.what, file = file, body = payload(built, file) })
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------
-- It rides each admin's own RM_Update (prmDiscord), as update.lua's state
-- does, so a client that bound its events before this add-on existed still
-- gets it.
function M.snapshot(pid)
  local cfg, ok = M.config()
  return {
    configured = cfg.webhook ~= nil,
    hint       = M.hint(cfg.webhook),
    thread     = cfg.webhook and cfg.webhook:find('thread_id=', 1, true) ~= nil or nil,
    post       = cfg.post,
    attach     = cfg.attach,
    sending    = M.job ~= nil,
    queued     = #M.queue,
    last       = M.last,
    canRetry   = M.failed ~= nil and M.job ~= M.failed or nil,
    canEdit    = host.isFull(pid) == true,
    error      = not ok and ('Data/' .. M.FILE .. ' on the server does not parse: nothing is '
      .. 'posted until it is fixed or deleted.') or nil,
  }
end

local function decode(raw)
  local ok, data = pcall(Util.JsonDecode, raw or '')
  if ok and type(data) == 'table' then return data end
  return {}
end

local function refuse(pid, msg)
  notice(pid, msg)
  push()
end

-- The admin tier's: the webhook speaks for the server in public.
function M.set(pid, raw)
  if not host.requireFull(pid) then return end
  local data = decode(raw)
  local cfg, ok = M.config()
  if not ok then
    return refuse(pid, 'Data/' .. M.FILE .. ' on the server does not parse, so it cannot be '
      .. 'changed from here. Fix it or delete it.')
  end
  local said = {}
  if data.clear == true then
    if cfg.webhook then said[#said + 1] = 'webhook ' .. M.hint(cfg.webhook) .. ' removed' end
    cfg.webhook = nil
  elseif data.webhook ~= nil then
    local url = M.checkWebhook(data.webhook)
    if not url then
      return refuse(pid, 'That is not a Discord webhook URL. In Discord: Edit Channel, '
        .. 'Integrations, Webhooks, Copy Webhook URL.')
    end
    cfg.webhook = url
    said[#said + 1] = 'webhook ' .. M.hint(url) .. ' set'
  end
  if type(data.post) == 'table' then
    for _, k in ipairs(M.KINDS) do
      if type(data.post[k]) == 'boolean' and cfg.post[k] ~= data.post[k] then
        cfg.post[k] = data.post[k]
        said[#said + 1] = k .. (data.post[k] and ' on' or ' off')
      end
    end
  end
  if type(data.attach) == 'boolean' and cfg.attach ~= data.attach then
    cfg.attach = data.attach
    said[#said + 1] = 'results file ' .. (data.attach and 'attached' or 'not attached')
  end
  if #said == 0 then return push() end
  if not save(cfg) then return refuse(pid, 'Could not write Data/' .. M.FILE .. ' on the server.') end
  print('[RaceManager] Discord: ' .. table.concat(said, ', ') .. ' by '
    .. tostring(MP.GetPlayerName(pid) or pid))
  push()
end

function M.test(pid)
  if not host.requireFull(pid) then return end
  local cfg = M.config()
  if not cfg.webhook then return refuse(pid, 'Set a webhook first.') end
  local built = M.build.test({ post = cfg.post, who = MP.GetPlayerName(pid) })
  M.enqueue({ kind = 'test', what = built.what, body = payload(built), notify = pid })
end

-- Either tier: it sends what already failed to send, nothing new.
function M.retry(pid)
  if not host.requireAuth(pid) then return end
  local job = M.failed
  if not job or M.job == job then return push() end
  M.failed = nil
  job.notify = pid
  M.enqueue(job)
end

-- At boot: clear what a post left behind (post.cfg holds the URL) and say
-- whether posting is on.
function M.warm()
  local dir = jobDir()
  local listed, found = pcall(host.listDirectory, at(dir))
  for _, name in ipairs(listed and found or {}) do os.remove(at(dir .. '/' .. name)) end
  local cfg = M.config()
  if cfg.webhook then
    local on = {}
    for _, k in ipairs(M.KINDS) do if cfg.post[k] then on[#on + 1] = k end end
    print('[RaceManager] Discord: posting ' .. (#on > 0 and table.concat(on, ', ') or 'nothing')
      .. ' results to webhook ' .. M.hint(cfg.webhook))
  end
end

-- The RM_Discord* globals, installed here and not at file scope: see the top.
function M.init(h)
  host = h
  M.host = h
  function RM_onDiscordSet(pid, raw) M.set(pid, raw) end
  function RM_onDiscordTest(pid) M.test(pid) end
  function RM_onDiscordRetry(pid) M.retry(pid) end
  function RM_DiscordTick() M.tick() end
end

return M
