-- Headless test for UPDATES FROM GITHUB (server/RaceManager/update.lua), run
-- against the real server plugin. Run from the repo root: lua5.3 tests/update_test.lua
--
-- Builds a scratch server folder and release zips in memory, then plays the
-- check, the ask and the update the way GitHub and an admin would. Nothing here
-- reaches the network or starts a process: a download is answered by writing
-- the files its job would have left, and maps.sys stands in for exit().

local connected = {}
local sent = {}          -- [event] = list of { target, payload }
local dropped = {}       -- [pid] = kick reason
local chat = {}

for i = 1, 4 do connected[i] = 'Driver' .. i end

MP = {
  GetPlayerName = function (pid) return connected[pid] end,
  SendChatMessage = function (_, msg) chat[#chat + 1] = msg end,
  GetPlayers = function ()
    local t = {}
    for id, name in pairs(connected) do t[id] = name end
    return t
  end,
  TriggerClientEvent = function (target, event, payload)
    sent[event] = sent[event] or {}
    table.insert(sent[event], { target = target, payload = payload })
  end,
  DropPlayer = function (pid, reason) dropped[pid] = reason end,
  RegisterEvent = function () end,
  CreateEventTimer = function () end,
  CancelEventTimer = function () end,
  Settings = { Map = 0 },
  Get = function () return '/levels/gridmap_v2/info.json' end,
  Set = function () end,
}

Util = {
  JsonEncode = function (t) return t end,
  JsonDecode = function (s)
    local body = s:gsub('"([%w_]+)"%s*:', '%1='):gsub('%[', '{'):gsub('%]', '}')
    return load('return ' .. body)()
  end,
}

dofile('server/RaceManager/main.lua')
local update = require('update')
local maps = require('maps')
local CFG = update.host.CFG
local CURRENT = update.host.RM_BUILD   -- the build under test, not a number written here

local checks, fails = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then fails = fails + 1; print('FAIL: ' .. msg) end
end

local function last(event, target)
  local list = sent[event] or {}
  for i = #list, 1, -1 do
    if target == nil or list[i].target == target then return list[i].payload end
  end
end

local function fromHex(h) return (h:gsub('%x%x', function (x) return string.char(tonumber(x, 16)) end)) end

-- ---------------------------------------------------------------------------
-- 1. Nothing global at file scope
-- ---------------------------------------------------------------------------
-- BeamMP runs every .lua in the plugin folder on its own, and update sorts
-- after main. A handler defined at load would be replaced by a dead copy.
do
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadfile('server/RaceManager/update.lua', 't', env))
  chunk()
  local leaked = {}
  for k in pairs(env) do leaked[#leaked + 1] = k end
  check(#leaked == 0, 'update.lua defines no globals when BeamMP runs it on its own (found: '
    .. table.concat(leaked, ', ') .. ')')
  check(type(RM_onUpdateStart) == 'function' and type(RM_UpdateTick) == 'function',
    'and main.lua installed the handlers through init')
end

-- ---------------------------------------------------------------------------
-- 2. Versions
-- ---------------------------------------------------------------------------
check(update.newer('0.22.0', '0.21.0') and update.newer('v0.21.10', '0.21.9')
  and update.newer('1.0.0', '0.99.99'), 'newer compares each number, not the text')
check(not update.newer('0.21.0', '0.21.0') and not update.newer('0.20.9', '0.21.0'),
  'the same or an older version is not newer')
check(not update.newer('0.22', '0.21.0') and not update.newer('0.22.0-beta', '0.21.0')
  and not update.newer(nil, '0.21.0'), 'anything that is not x.y.z is never newer')

-- ---------------------------------------------------------------------------
-- 3. SHA-256 and CRC-32
-- ---------------------------------------------------------------------------
local PATTERN = {}
for i = 0, 69999 do PATTERN[#PATTERN + 1] = string.char(((i * 7919) >> 3) & 255) end
PATTERN = table.concat(PATTERN)
check(update.sha256('') == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  and update.sha256('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'SHA-256 of the empty string and of abc')
check(update.sha256('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')
  == '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
  'SHA-256 over two blocks')
check(update.sha256(string.rep('a', 1000)) == '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3'
  and update.sha256(PATTERN) == '47db5481395388a93fa342b49ec4e0efddfbe64446bde4531843dad18d532038',
  'SHA-256 of longer data, of lengths that are not a whole block')
check(update.crc32('123456789') == 0xCBF43926 and update.crc32(PATTERN) == 0x748ebfa3,
  'CRC-32 matches zlib')

-- ---------------------------------------------------------------------------
-- 4. Inflate
-- ---------------------------------------------------------------------------
-- Raw deflate streams from Python's zlib (wbits -15), and stored blocks built
-- here. The text the dynamic one holds is rebuilt the same way in both.
local function numbersText(n)
  local t = {}
  for i = 1, n do t[i] = i .. ':' .. ((i * 7919) % 1000) .. ';' end
  return table.concat(t)
end
local DYNAMIC = fromHex(table.concat({
  '15d4518ec5300843d12dc5900482f7bfafde7e551a6978c53d46f3f41cd3d9cea953de73ebfacc79c7778eb66b76a67bf284',
  'df44c95aa3b72c8dd6b362a2ad9cb7cbdad3f75a67aa8f75a7d6b66a6ea4d57376586ff695634df67268e2f10a0c513b7294',
  'e5d873aee3ccabe3b8d36f3b6a5ae9e8a90cc79b7be45c736a3935bb9f33662f16c9c928e79ed8d77946f73899b29d35e9ec',
  '7911cec75fe4bda6eef2168b3fef60f3f64e56278ccdeed7fbb0fcf1be6cbfbd8bedd3bb470aef37299f35ef2c1fb1fdf309',
  'b66f1f125de543a441a464ba8fcf65fbedc38b74fa10eb0a1f720df992eb5ebee21d7c83eddb37d9be7cc955d7975c930f73',
  'd97efb16dba76fcf7ee14bae928b5c73b9c8753f57b07dbb98522edec445aa715c7f1e7cdc62fb74f5dc0e17a92eb9493596',
  '9b54f3b983eddb9d6c5feecdf6d74daa3aee3bb9ddc5f610697e24dc6feac98f5cb5fcc8359e1fb9eef64bb62fbfcdf6d78f',
  '5cd7f123d7d87ee4bad38f5701da9bd7bf34825d505b248b542da2c5aa569200dc1652f0aa75c800708b7831ab45bea8d5ea',
  '09dce274f4cbd53f8f878661c87d3f5decf66f17bcf5e345effdf5c2f7fe7cf17b7ebf00de3f6004278205e180b030acf717',
  '81b0412c148358287e30168e1bc702720159482e240bca17cac2f2c1b2c0bcc12c34279a05e75c7fb3481ecf02b4002d4403',
  '5a887e90a62facc4385837ac85ebc23592e6025bc83ec816b437b4c99888fea6f211c02d7407ba194d44ccc337bcf5fb661a',
  'be1fc085f046b8205e1017c62fc605f20b72a1fcc45f7c3e04cc85f3c4b9801e4017d203e9823a797119589671587f6017da',
  '1bed827bc15d782fbcd35c32fa0f09b708f182fc863ca62731affbd78f71a80fd4f38dc98879f5bf1e0fae12f0d98b8c1807',
  'fe06bfd05ffb3f4c5c26f80bff07ffa200870288066c1a202a9054407420e8802801ffc393798cfb5bc0345af0a881e8419f',
  'ffce71a3288268c2a509dccab9544174e1d00551864d19b82264c434ea10d441f421e803fd2223e6bdfff4f2e05eddff6e72',
  'b0fa3f9c7c8ab5fc01',
}))
local textOut = numbersText(200)
check(#textOut == 1468 and update.crc32(textOut) == 0xc7183323, 'the dynamic vector holds the text it should')
check(update.inflate(DYNAMIC, #textOut) == textOut, 'a dynamic Huffman block')
check(update.inflate(fromHex('0bc8c84fcdcbac50084a4c4e55f04dcc4b4c4f2d0200'), 20) == 'Phoenix Race Manager',
  'a fixed Huffman block')
check(update.inflate(fromHex('4b4c1c05a360140c770000'), 1000) == string.rep('a', 1000),
  'a run: a match that overlaps the bytes it is copying')

-- Two stored blocks: one full, then the rest, and the second one final.
local function stored(data)
  local out, i = {}, 1
  repeat
    local piece = data:sub(i, i + 65534)
    i = i + #piece
    out[#out + 1] = string.char(i > #data and 1 or 0) .. string.pack('<I2I2', #piece, #piece ~ 0xFFFF) .. piece
  until i > #data
  return table.concat(out)
end
check(update.inflate(stored(PATTERN), #PATTERN) == PATTERN, 'stored blocks, across the 64 KB limit')

local function refuses(src, size, what)
  local ok, err = pcall(update.inflate, src, size)
  check(not ok and type(err) == 'string', what .. ' is refused (' .. tostring(err) .. ')')
end
refuses(DYNAMIC:sub(1, 300), #textOut, 'a stream cut short')
refuses('\7', 10, 'block type 3')
refuses(string.char(1, 5, 0, 0, 0) .. 'hello', 5, 'a stored block with a bad length')
refuses(fromHex('4b4c1c05a360140c770000'), 10, 'more output than the zip says')

-- ---------------------------------------------------------------------------
-- 5. Zips
-- ---------------------------------------------------------------------------
-- Stored entries, or { name, raw, method = 8, size, crc } for a deflated one.
local function zipOf(entries)
  local body, cd, offset = {}, {}, 0
  for _, e in ipairs(entries) do
    local name, raw, method = e[1], e[2], e.method or 0
    local size = e.size or #raw
    local crc = e.crc or update.crc32(raw)
    local lh = string.pack('<I4I2I2I2I2I2I4I4I4I2I2', 0x04034b50, 20, 0, method, 0, 0,
      crc, #raw, size, #name, 0) .. name
    body[#body + 1] = lh .. raw
    cd[#cd + 1] = string.pack('<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4', 0x02014b50, 20, 20, 0,
      method, 0, 0, crc, #raw, size, #name, 0, 0, 0, 0, 0, offset) .. name
    offset = offset + #lh + #raw
  end
  local cdData = table.concat(cd)
  return table.concat(body) .. cdData .. string.pack('<I4I2I2I2I2I4I4I2', 0x06054b50, 0, 0,
    #entries, #entries, #cdData, offset, 0)
end

do
  local z = zipOf({ { 'a.txt', 'hello' }, { 'dir/', '' },
    { 'b.txt', DYNAMIC, method = 8, size = #textOut, crc = 0xc7183323 } })
  local list = update.zipEntries(z)
  check(list and #list == 3 and list[3].name == 'b.txt' and list[3].method == 8, 'the directory is read')
  check(update.zipRead(z, list[1]) == 'hello' and update.zipRead(z, list[3]) == textOut,
    'stored and deflated entries come out whole')
  local broken = z:gsub('hello', 'jello')
  local bytes, why = update.zipRead(broken, update.zipEntries(broken)[1])
  check(bytes == nil and why:find('checksum'), 'a changed byte fails the CRC')
  check(update.zipEntries('this is not a zip') == nil, 'something that is not a zip is refused')
end

-- ---------------------------------------------------------------------------
-- 6. The release GitHub describes
-- ---------------------------------------------------------------------------
local REPO = 'aosjay13/BeamNG-Race-Manager-by-Phoenix'
local function release(fields)
  local r = {
    tag_name = 'v9.9.9', name = 'v9.9.9 - Faster pit stops', draft = false, prerelease = false,
    body = '## Added\n- A thing', assets = { {
      name = 'RaceManager-v9.9.9.zip', size = 4096, digest = 'sha256:' .. string.rep('ab', 32),
      browser_download_url = 'https://evil.example/x.zip',
    } },
  }
  for k, v in pairs(fields or {}) do r[k] = v end
  return r
end
do
  local r = update.readRelease(release(), REPO)
  check(r and r.version == '9.9.9' and r.title == 'Faster pit stops' and r.notes == 'Added\n- A thing',
    'a release reads as version, title and notes')
  check(update.plainNotes('#### Added\n\n- **Bold** with `code`, *PRM* and [a link](https://x.y/z)\n* a bullet')
    == 'Added\n\n- Bold with code, PRM and a link\n* a bullet',
    'the notes lose their Markdown marks and keep their words')
  check(update.plainNotes('#### Fixed\n- one\n  **two**\nthree\n\nA new\nparagraph\n- next')
    == 'Fixed\n- one two three\n\nA new paragraph\n- next',
    'hard-wrapped lines are rejoined, bold at the start too, and a new item or paragraph is not')
  check(r and r.download == 'https://github.com/' .. REPO .. '/releases/download/v9.9.9/RaceManager-v9.9.9.zip',
    'the download URL is built from the repo and version, never the one GitHub sent')
  for _, tag in ipairs({ 'v9.9.9"&calc&"', 'v9.9', 'latest', '9.9.9', 'v9.9.9 ' }) do
    check(update.readRelease(release({ tag_name = tag }), REPO) == nil, 'tag "' .. tag .. '" is refused')
  end
  check(update.readRelease(release({ draft = true }), REPO) == nil, 'a draft is refused')
  local noAsset = release()
  noAsset.assets[1].name = 'RaceManager-v9.9.8.zip'
  check(update.readRelease(noAsset, REPO) == nil, 'a release without its own zip is refused')
  local noDigest = release()
  noDigest.assets[1].digest = nil
  check(select(2, update.readRelease(noDigest, REPO)):find('SHA%-256'), 'no SHA-256, no update')
  local tiny = release()
  tiny.assets[1].size = 12
  check(update.readRelease(tiny, REPO) == nil, 'a zip of a few bytes is not a release')
  check(update.validRepo(REPO) and update.validRepo('a-b/c_d.e'), 'owner/name passes')
  for _, bad in ipairs({ 'nope', 'a/b c', 'a/b"', 'a/../b', '-a/b', 'a/b;rm' }) do
    check(not update.validRepo(bad), 'repo "' .. bad .. '" is refused')
  end
  check(update.downloadError(22, 'curl: (22) The requested URL returned error: 403'):find('an hour'),
    'a 403 from GitHub says it is the rate limit')
  check(update.downloadError(9009, ''):find('curl.exe'), 'a missing curl.exe says so')
end

-- ---------------------------------------------------------------------------
-- 7. Unpacking a release
-- ---------------------------------------------------------------------------
local CLIENT = zipOf({
  { 'lua/ge/extensions/raceManager.lua', '-- new client' },
  { 'scripts/raceManager/modScript.lua', 'load("raceManager")' },
  { 'ui/modules/apps/RaceManager/app.js', '// app' },
})
local NEW_MAIN = "-- new main\nlocal RM_BUILD = '9.9.9'\nreturn RM_BUILD\n"
local function releaseZip(extra, mainSrc, client)
  local list = {
    { 'LICENSE', 'MIT' }, { 'Client/', '' }, { 'Client/RaceManager.zip', client or CLIENT },
    { 'Server/', '' }, { 'Server/RaceManager/', '' },
    { 'Server/RaceManager/main.lua', mainSrc or NEW_MAIN },
    { 'Server/RaceManager/maps.lua', '-- new maps\nreturn {}\n' },
    { 'Server/RaceManager/update.lua', '-- new update\nreturn {}\n' },
  }
  for _, e in ipairs(extra or {}) do list[#list + 1] = e end
  return zipOf(list)
end
do
  local files = update.unpackRelease(releaseZip(), '9.9.9')
  check(files and files.client == CLIENT and files.server['main.lua'] == NEW_MAIN
    and files.server['update.lua'] and not files.server.LICENSE, 'the client zip and the plugin files')
  local function refusal(zip, version, want, what)
    local f, why = update.unpackRelease(zip, version or '9.9.9')
    check(f == nil and type(why) == 'string' and why:find(want), what .. ' (' .. tostring(why) .. ')')
  end
  refusal(releaseZip({ { 'Server/RaceManager/Data/config.json', '{}' } }), nil, 'by hand',
    'a file it does not know where to put stops the update: never half a release, never Data')
  refusal(releaseZip({ { 'Server/RaceManager/lib/x.lua', '' } }), nil, 'by hand', 'and so does a nested module')
  refusal(releaseZip(), '9.9.8', 'build 9.9.9', 'a zip whose main.lua is another build')
  refusal(releaseZip(nil, "\nlocal RM_BUILD = '9.9.9'\nlocal x = = 1\n"), nil, 'compile',
    'a main.lua that does not compile')
  refusal(releaseZip(nil, nil, zipOf({ { 'raceManager/lua/ge/extensions/raceManager.lua', '' } })), nil,
    'has no lua/ge', 'a client zip with an extra folder level')
  refusal(releaseZip(nil, nil, string.rep('not a zip ', 10)), nil, 'not a zip',
    'a client zip that is not a zip')
end

-- ---------------------------------------------------------------------------
-- A scratch server folder
-- ---------------------------------------------------------------------------
local IS_WINDOWS = package.config:sub(1, 1) == '\\'
local base = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp'):gsub('\\', '/')
local root = base .. '/rm_update_test_' .. os.time()

local function mkdir(p)
  if IS_WINDOWS then os.execute('mkdir "' .. p:gsub('/', '\\') .. '" 2>nul')
  else os.execute('mkdir -p "' .. p .. '"') end
end
local function write(p, s)
  local f = assert(io.open(p, 'wb'))
  f:write(s)
  f:close()
end
local function read(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end
local function exists(p) return read(p) ~= nil end

local PLUGIN = root .. '/Resources/Server/RaceManager'
local OLD = {
  client = 'OLD CLIENT ZIP',
  main   = "-- old main\nlocal RM_BUILD = '0.21.0'\n",
  maps   = '-- old maps\n',
  update = '-- old update\n',
  stale  = '-- a module the new release no longer has\n',
}
local function freshServer()
  mkdir(root .. '/Resources/Client')
  mkdir(PLUGIN .. '/Data/results')
  write(root .. '/ServerConfig.toml', 'Port = 30814\r\nMap = "/levels/gridmap_v2/info.json"\r\n')
  write(root .. '/Resources/Client/RaceManager.zip', OLD.client)
  write(root .. '/Resources/Client/othermod.zip', 'SOMEONE ELSE')
  write(PLUGIN .. '/main.lua', OLD.main)
  write(PLUGIN .. '/maps.lua', OLD.maps)
  write(PLUGIN .. '/update.lua', OLD.update)
  write(PLUGIN .. '/stale.lua', OLD.stale)
  write(PLUGIN .. '/Data/config.json', '{"adminPassword": "theirs"}')
  write(PLUGIN .. '/Data/results/race.txt', 'P1 somebody')
end
local function untouched()
  return read(root .. '/Resources/Client/RaceManager.zip') == OLD.client
    and read(PLUGIN .. '/main.lua') == OLD.main and read(PLUGIN .. '/maps.lua') == OLD.maps
    and read(PLUGIN .. '/stale.lua') == OLD.stale
end
freshServer()

update.paths.root = root
update.paths.plugin = 'Resources/Server/RaceManager'
update.paths.data = 'Resources/Server/RaceManager/Data'
maps.paths.root = root
maps.paths.data = 'Resources/Server/RaceManager/Data'

local spawned, exited = {}, 0
update.sys = {
  popen = function () return nil end,
  execute = function (cmd) spawned[#spawned + 1] = cmd; return true end,
}
maps.sys = {
  popen = function () return nil end,
  execute = function (cmd) spawned[#spawned + 1] = cmd; return true end,
  exit = function () exited = exited + 1 end,
}
maps.probe = function ()
  return { pid = 4242, exe = 'C:\\BeamNG Server\\BeamMP-Server.exe', name = 'BeamMP-Server.exe',
    cmd = '"C:\\BeamNG Server\\BeamMP-Server.exe"', cwd = 'C:\\BeamNG Server',
    parent = 'explorer.exe', args = {}, mt = {} }
end

local function tick(n) for _ = 1, n or 1 do RM_UpdateTick() end end

-- Answer the running job as curl would have.
local function finishJob(code, body, stderr)
  local job = update.job
  if body then write(root .. '/' .. job.outRel, body) end
  if stderr then write(root .. '/' .. job.errRel, stderr) end
  write(root .. '/' .. job.doneRel, tostring(code) .. '\r\n')
end

-- The reply to /releases/latest, as JSON, for a given zip.
local function latestJson(version, zip, digest)
  return string.format('{"tag_name": "v%s", "name": "v%s - Faster pit stops", "draft": false, '
    .. '"prerelease": false, "body": "## Added\\n- A \\"quoted\\" thing", '
    .. '"html_url": "https://github.com/x", "assets": [{"name": "RaceManager-v%s.zip", '
    .. '"size": %d, "digest": "sha256:%s", "browser_download_url": "https://evil.example/x.zip"}]}',
    version, version, version, #zip, digest or update.sha256(zip))
end

local ADMIN, MOD, DRIVER = 1, 2, 3
local function stateFor(pid)
  RM_onRequestState(pid, '')
  return last('RM_Update', pid)
end

-- ---------------------------------------------------------------------------
-- 8. The startup check
-- ---------------------------------------------------------------------------
-- Before anyone logs in, as at boot: a login on a server that has not looked
-- yet starts a look of its own.
CFG.updateCheck = false
update.warm()
check(not update.pendingCheck, 'updateCheck false: GitHub is never asked')
CFG.updateCheck = true

update.warm()
check(update.pendingCheck and update.job == nil, 'at boot the check waits for the first tick')
tick()
local job = update.job
check(job and job.name == 'check' and job.url == 'https://api.github.com/repos/' .. REPO .. '/releases/latest',
  'the first tick asks the GitHub API for the newest release')
local script = read(root .. '/' .. job.script) or ''
if IS_WINDOWS then
  check(script:find('%SystemRoot%\\System32\\curl.exe', 1, true) and script:find('echo %errorlevel%', 1, true),
    'Windows: the job runs System32 curl and writes its exit code')
  check(spawned[#spawned]:find('Start-Process', 1, true) and spawned[#spawned]:find('Hidden', 1, true),
    'and is started through Start-Process, which hands it none of the server\'s sockets')
else
  check(script:find('exec $n>&-', 1, true) and script:find('wget', 1, true),
    'Linux: the job closes the server\'s sockets, and has wget when curl is missing')
end
check(script:find(job.url, 1, true) ~= nil, 'the job fetches exactly that URL')

local zip = releaseZip()
finishJob(0, latestJson('9.9.9', zip))
tick()
check(update.release.latest and update.release.latest.version == '9.9.9' and update.job == nil,
  'the reply is read: v9.9.9 is out')
check(not exists(root .. '/' .. job.outRel) and not exists(root .. '/' .. job.doneRel),
  'and the job leaves nothing behind')

RM_onLogin(ADMIN, '{"password":"phoenix"}')
RM_onChangePassword(ADMIN, '{"password":"tuesday","role":"moderator"}')
RM_onLogin(MOD, '{"password":"tuesday"}')
check(update.job == nil, 'a login just after a look does not ask GitHub again')

local st = stateFor(ADMIN)
check(st.prmUpdate and st.prmUpdate.available and st.prmUpdate.latest == '9.9.9'
  and st.prmUpdate.current == CURRENT and st.prmUpdate.canUpdate == true,
  'an admin is told, and may install it')
check(st.prmUpdate and st.prmUpdate.notes == 'Added\n- A "quoted" thing', 'with the release notes')
st = stateFor(MOD)
check(st.prmUpdate and st.prmUpdate.available and st.prmUpdate.canUpdate == false,
  'a moderator is told, and may not install it')
st = stateFor(DRIVER)
check(st.prmUpdate == nil, 'a driver hears nothing of it')

-- A failed look: the reason, and the rate limit said plainly.
RM_onUpdateCheck(ADMIN)
check(update.job and update.job.name == 'check', 'Check now asks again')
finishJob(22, nil, 'curl: (22) The requested URL returned error: 403')
tick()
check(update.release.error and update.release.error:find('an hour')
  and update.release.latest.version == '9.9.9', 'a failed check says why and keeps what it knew')

-- ---------------------------------------------------------------------------
-- 9. Who may start one, and when
-- ---------------------------------------------------------------------------
RM_onUpdateStart(DRIVER, '{"version":"9.9.9"}')
check(update.state.phase == 'idle', 'a driver cannot start an update')
RM_onUpdateStart(MOD, '{"version":"9.9.9"}')
check(update.state.phase == 'idle' and last('RM_Denied', MOD), 'nor can a moderator: it is the admin tier\'s')
RM_onUpdateStart(ADMIN, '{"version":"9.9.8"}')
check(update.state.phase == 'idle' and update.lastError:find('v9.9.9'),
  'a version the admin did not see is refused')
do
  local realBusy = update.host.busy
  update.host.busy = function () return 'a session is running' end
  RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
  check(update.state.phase == 'idle' and update.lastError:find('session'), 'not while a session runs')
  update.host.busy = realBusy
  CFG.mapRestart = 'manual'
  RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
  check(update.state.phase == 'idle' and update.lastError:find('manual')
    and update.lastError:find('github.com', 1, true), 'restarts set to manual: install by hand, here is where')
  CFG.mapRestart = 'auto'
end

-- ---------------------------------------------------------------------------
-- 10. The update
-- ---------------------------------------------------------------------------
spawned = {}
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
job = update.job
check(update.state.phase == 'downloading' and update.state.method == 'relaunch',
  'an admin starts it: downloading, to be restarted by Race Manager')
check(job and job.url == 'https://github.com/' .. REPO .. '/releases/download/v9.9.9/RaceManager-v9.9.9.zip',
  'from the github.com release, not the URL the reply carried')
RM_onMapSwitch(ADMIN, '{"map":"gridmap_v2"}')
check(maps.state.phase == 'idle', 'no map switch while an update is under way')

finishJob(0, zip)
tick()
check(update.state.phase == 'countdown' and update.state.left == update.COUNTDOWN,
  'the download is checked, then everyone gets the countdown')
check(chat[#chat]:find('v9.9.9', 1, true) and last('RM_Notice', -1).msg == 'Server update',
  'in chat and on every driver\'s screen')
check(untouched() and next(dropped) == nil, 'and nothing has changed yet')
tick(update.COUNTDOWN)
check(update.state.phase == 'kicking' and dropped[DRIVER] and dropped[ADMIN],
  'at zero everyone is disconnected, admins included')
check(RM_Update_onPlayerAuth() ~= nil, 'and joining is refused until the server stops')
tick(update.SETTLE)
check(exited == 1, 'then the server stops')
check(#spawned == 2 and spawned[2]:find('relaunch', 1, true), 'after the helper that restarts it')
check(read(root .. '/Resources/Client/RaceManager.zip') == CLIENT
  and read(PLUGIN .. '/main.lua') == NEW_MAIN and read(PLUGIN .. '/update.lua') == '-- new update\nreturn {}\n',
  'the client zip and the plugin are the new release')
check(not exists(PLUGIN .. '/stale.lua'), 'a module the release no longer has is gone: BeamMP would run it')
check(read(root .. '/Resources/Client/othermod.zip') == 'SOMEONE ELSE'
  and read(PLUGIN .. '/Data/config.json') == '{"adminPassword": "theirs"}'
  and read(PLUGIN .. '/Data/results/race.txt') == 'P1 somebody',
  'other mods and everything in Data are left alone')
local rec = read(PLUGIN .. '/Data/update/last.json') or ''
local attic = rec:match('"attic": "([^"]+)"')
check(attic and read(root .. '/' .. attic .. '/Client/RaceManager.zip') == OLD.client
  and read(root .. '/' .. attic .. '/Server/RaceManager/main.lua') == OLD.main
  and read(root .. '/' .. attic .. '/Server/RaceManager/stale.lua') == OLD.stale,
  'the replaced files are in the attic, the removed one too')

-- The restart, simulated: the new plugin boots.
update.host.RM_BUILD = '9.9.9'
update.state = { phase = 'idle' }
update.job, update.pendingCheck = nil, false
dropped = {}
update.warm()
check(update.last and update.last.ok and update.last.from == CURRENT and update.last.to == '9.9.9',
  'after the restart the update reads as done')
check((read(PLUGIN .. '/Data/update/last.json') or ''):find('"ok": true', 1, true),
  'and the record is kept, marked read, for the next boot to show')
tick()
finishJob(0, latestJson('9.9.9', zip))
tick()
st = stateFor(ADMIN)
check(st.prmUpdate and not st.prmUpdate.available and st.prmUpdate.last.ok,
  'the same release is not offered again')
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
check(update.state.phase == 'idle', 'and cannot be installed over itself')

-- ---------------------------------------------------------------------------
-- 11. When it goes wrong, nothing changes
-- ---------------------------------------------------------------------------
local function newRelease(version, z, digest)
  update.release.latest = update.readRelease(
    update.host.jsonParse(latestJson(version, z, digest)), REPO)
end
local function reboot()
  freshServer()
  update.host.RM_BUILD = CURRENT
  update.state = { phase = 'idle' }
  update.job, update.lastError = nil, nil
  exited, spawned, dropped = 0, {}, {}
end

-- The download is not the file GitHub lists.
reboot()
newRelease('9.9.9', zip, string.rep('0', 64))
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
finishJob(0, zip)
tick()
check(update.state.phase == 'idle' and update.lastError:find('SHA%-256') and untouched()
  and next(dropped) == nil, 'a download that fails its SHA-256: nobody is kicked, nothing changes')

-- The download itself fails.
reboot()
newRelease('9.9.9', zip)
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
finishJob(6, nil, 'curl: (6) Could not resolve host: github.com')
tick()
check(update.state.phase == 'idle' and update.lastError:find('offline') and untouched(),
  'a download that fails says why')

-- Nothing answers at all.
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
update.job.started = os.time() - update.FETCH_SECONDS - 60
tick()
check(update.state.phase == 'idle' and update.lastError:find('no answer') and update.job == nil,
  'a download that never finishes is given up on')

-- Stopped during the countdown.
reboot()
newRelease('9.9.9', zip)
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
finishJob(0, zip)
tick(3)
RM_onUpdateCancel(MOD)
check(update.state.phase == 'idle' and last('RM_Notice', -1).msg == 'Server update cancelled',
  'either tier can stop it, and the field is told')
tick(update.COUNTDOWN + update.SETTLE)
check(untouched() and exited == 0 and next(dropped) == nil, 'and nothing happens after')

-- Stopped during the download: the late answer is thrown away.
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
job = update.job
RM_onUpdateCancel(ADMIN)
finishJob(0, zip)
tick()
check(update.state.phase == 'idle' and update.job == nil and not exists(root .. '/' .. job.outRel),
  'a download that lands after Stop is deleted, not installed')

-- A file that will not write: everything is put back, and the server stays up.
reboot()
newRelease('9.9.9', zip)
os.remove(PLUGIN .. '/update.lua')
mkdir(PLUGIN .. '/update.lua')
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
finishJob(0, zip)
tick(1 + update.COUNTDOWN + update.SETTLE)
check(update.state.phase == 'idle' and update.lastError:find('put back as it was'),
  'a write that fails rolls the update back, and says so')
check(untouched() and exited == 0, 'the old files are all back, and the server keeps running')
if IS_WINDOWS then os.execute('rmdir "' .. (PLUGIN .. '/update.lua'):gsub('/', '\\') .. '" 2>nul')
else os.execute('rmdir "' .. PLUGIN .. '/update.lua"') end

-- A release this updater cannot place is refused before anyone is kicked.
reboot()
local odd = releaseZip({ { 'Server/RaceManager/README.md', 'hi' } })
newRelease('9.9.9', odd)
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
finishJob(0, odd)
tick()
check(update.state.phase == 'idle' and update.lastError:find('by hand') and next(dropped) == nil,
  'a release with a file it does not know is left for a hand install')

-- A map switch under way holds the update off.
reboot()
newRelease('9.9.9', zip)
maps.state = { phase = 'countdown', target = { label = 'X' } }
RM_onUpdateStart(ADMIN, '{"version":"9.9.9"}')
check(update.state.phase == 'idle' and update.lastError:find('map switch'), 'not during a map switch')
maps.state = { phase = 'idle' }

-- ---------------------------------------------------------------------------
-- 12. A bad repo never reaches a shell
-- ---------------------------------------------------------------------------
CFG.updateRepo = 'x/y" & calc'
spawned = {}
update.job = nil
local ok = update.startCheck('test')
check(not ok and #spawned == 0 and update.release.error:find('owner/name'),
  'an updateRepo that is not owner/name starts nothing')
CFG.updateRepo = REPO

if IS_WINDOWS then os.execute('rmdir /s /q "' .. root:gsub('/', '\\') .. '"')
else os.execute('rm -rf "' .. root .. '"') end

print(string.format('update_test: %d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
