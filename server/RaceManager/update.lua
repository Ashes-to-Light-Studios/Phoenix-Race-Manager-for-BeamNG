-- Race Manager: UPDATES FROM GITHUB, as its own module.
--
-- At startup the server asks GitHub for the newest release, in the background.
-- A newer one is offered to the admins: the panel asks, and the Admin tab has
-- Update and restart, which downloads the release zip, checks it, swaps the
-- files in and restarts the server through maps.lua, the way a map switch does.
--
-- NOTHING GLOBAL AT FILE SCOPE: BeamMP runs this file a second time on its own
-- (see maps.lua), so the handlers are installed by init().
--
-- WHAT IS TRUSTED. The SHA-256 GitHub lists proves the download is the file the
-- repo published, not who published it. So only an admin starts an update,
-- never the server on its own, and nothing GitHub sends reaches a shell: the
-- download URL is rebuilt from the configured repo and a checked version.
--
-- NO UNZIP TOOL: many Linux hosts have none, so the zip is read here. SHA-256,
-- CRC-32 and inflate in plain Lua take about a second for a release, and run
-- only while no session is.

local M = {}
local host

local IS_WINDOWS = package.config:sub(1, 1) == '\\'

M.REPO          = 'aosjay13/BeamNG-Race-Manager-by-Phoenix'
M.COUNTDOWN     = 10       -- seconds of warning before everyone is disconnected
M.SETTLE        = 2        -- then this long, for download streams to close
M.CHECK_SECONDS = 30       -- curl's limit for asking GitHub
M.FETCH_SECONDS = 300      -- and for the zip
M.RECHECK       = 6 * 3600 -- an admin logging in after this long asks again
M.MAX_ZIP       = 32 * 1024 * 1024
M.MAX_NOTES     = 4000

-- Relative to the server's working directory. `plugin` is this file's own
-- folder, the one BeamMP loaded. Tests point all of them at a scratch folder.
M.paths = {
  root   = '',
  plugin = (debug.getinfo(1, 'S').source:sub(2):gsub([[\]], '/'):match('^(.*)/[^/]+$'))
    or 'Resources/Server/RaceManager',
  data   = 'Resources/Server/RaceManager/Data',
  attic  = '_attic',
}

-- Process calls, as a table so the tests can stand in for them.
M.sys = { popen = io.popen, execute = os.execute }

-- idle | downloading | verifying | countdown | kicking | applying
M.state = { phase = 'idle' }
M.lastError = nil   -- why the last attempt stopped
M.last = nil        -- the previous update, read back after its restart
-- What GitHub said: { at, latest, error }. `latest` is a checked release.
M.release = {}
M.job = nil         -- the background download, if one is running
M.pendingCheck = false

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

local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return false
end

local function pause(seconds)
  local stop = os.clock() + seconds
  while os.clock() < stop do end
end

-- Read back every time: a full disk writes short without raising. A few tries,
-- because a handle a download stream left open fails a write for a moment.
local function writeFile(path, data)
  for try = 1, 4 do
    local f = io.open(path, 'wb')
    if f then
      local ok = f:write(data)
      f:close()
      if ok and readFile(path) == data then return true end
    end
    if try < 4 then pause(0.25) end
  end
  return false
end

local function removeFile(path)
  if not exists(path) then return true end
  for try = 1, 4 do
    host.removeFile(path)
    if not exists(path) then return true end
    if try < 4 then pause(0.25) end
  end
  return false
end

local function workDir() return M.paths.data .. '/update' end

local function clientDir()
  local res = M.paths.plugin:match('^(.+)/[Ss]erver/[^/]+$')
  if not res then
    local text = readFile(at('ServerConfig.toml')) or ''
    res = text:match('\n[ \t]*ResourceFolder[ \t]*=[ \t]*"([^"\r\n]+)"') or 'Resources'
  end
  return res .. '/Client'
end

local function cfg(key, fallback)
  local v = host and host.CFG and host.CFG[key]
  if v == nil then return fallback end
  return v
end

-- ---------------------------------------------------------------------------
-- Text, versions and the release
-- ---------------------------------------------------------------------------
-- Printable, valid UTF-8, at most `max` characters, or nil. Util.JsonEncode
-- throws on a broken byte, and this rides the admin's state push.
function M.cleanText(raw, max)
  if type(raw) ~= 'string' then return nil end
  local s = raw:gsub('\r\n', '\n'):gsub('[\0-\9\11-\31\127]', '')
  if not utf8.len(s) then s = s:gsub('[\128-\255]', '') end
  if utf8.len(s) > max then s = s:sub(1, utf8.offset(s, max + 1) - 1) .. '...' end
  s = s:gsub('^%s+', ''):gsub('%s+$', '')
  if s == '' then return nil end
  return s
end

-- The notes are Markdown and the panel shows text: heading marks, emphasis,
-- code ticks and link targets come out, the words stay. A bullet's "* " is
-- not emphasis and is left alone. The CHANGELOG is hard-wrapped at 80, so a
-- line that continues the one above is rejoined: the box wraps to its width.
function M.plainNotes(md)
  if type(md) ~= 'string' then return nil end
  local lines = {}
  for line in (md:gsub('\r\n', '\n') .. '\n'):gmatch('(.-)\n') do
    local text = line:gsub('^[ \t]+', '')
    local prev = lines[#lines]
    -- A bullet is its mark AND a space: "**Grid** tab" continues a line.
    if text ~= '' and prev and prev ~= '' and not prev:match('^#') and not text:match('^[#>|]')
        and not text:match('^[%-%*+]%s') and not text:match('^%d+[%.%)]%s') then
      lines[#lines] = prev .. ' ' .. text
    else
      lines[#lines + 1] = text == '' and '' or line
    end
  end
  local s = ('\n' .. table.concat(lines, '\n'))
    :gsub('\n#+[ \t]*', '\n')
    :gsub('%*%*', ''):gsub('__', ''):gsub('`', '')
    :gsub('%*(%S[^%*\n]-%S)%*', '%1')
    :gsub('%[([^%]\n]+)%]%([^%)\n]+%)', '%1')
  return M.cleanText(s, M.MAX_NOTES)
end

function M.parseVersion(s)
  if type(s) ~= 'string' or #s > 20 then return nil end
  local a, b, c = s:match('^v?(%d+)%.(%d+)%.(%d+)$')
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

-- Is version a newer than version b? False when either is not a version.
function M.newer(a, b)
  local x, y = M.parseVersion(a), M.parseVersion(b)
  if not (x and y) then return false end
  for i = 1, 3 do
    if x[i] ~= y[i] then return x[i] > y[i] end
  end
  return false
end

-- owner/name as GitHub allows them. It becomes part of a URL a shell runs.
function M.validRepo(s)
  return type(s) == 'string' and #s <= 140 and s:match('^[%w][%w%-]*/[%w%-%._]+$') ~= nil
    and not s:find('..', 1, true)
end

-- The reply to /releases/latest, checked field by field. The asset's own URL
-- is never used: the download is rebuilt from the repo and the version.
function M.readRelease(data, repo)
  if type(data) ~= 'table' then return nil, 'GitHub did not send a release' end
  local tag = data.tag_name
  local version = type(tag) == 'string' and tag:match('^v(%d+%.%d+%.%d+)$')
  if not version or not M.parseVersion(version) then
    return nil, 'the newest release is tagged "' .. tostring(M.cleanText(tostring(tag), 40))
      .. '", which is not a version'
  end
  if data.draft == true or data.prerelease == true then
    return nil, 'the newest release is a draft or a prerelease'
  end
  local asset = 'RaceManager-v' .. version .. '.zip'
  local found
  for _, a in ipairs(type(data.assets) == 'table' and data.assets or {}) do
    if type(a) == 'table' and a.name == asset then found = a end
  end
  if not found then return nil, 'release v' .. version .. ' has no ' .. asset end
  local digest = type(found.digest) == 'string' and found.digest:lower():match('^sha256:(%x+)$')
  if not digest or #digest ~= 64 then
    return nil, 'GitHub lists no SHA-256 for ' .. asset .. ', so it cannot be checked'
  end
  local size = math.tointeger(tonumber(found.size) or -1)
  if not size or size < 1024 or size > M.MAX_ZIP then
    return nil, asset .. ' is ' .. tostring(found.size) .. ' bytes, which is not a release'
  end
  local name = M.cleanText(data.name, 160) or ''
  return {
    version  = version,
    asset    = asset,
    size     = size,
    digest   = digest,
    -- "v0.22.0 - Title" is how the release workflow names them.
    title    = (name:gsub('^v?%d+%.%d+%.%d+%s*%-?%s*', '')),
    notes    = M.plainNotes(data.body),
    url      = 'https://github.com/' .. repo .. '/releases/tag/v' .. version,
    download = 'https://github.com/' .. repo .. '/releases/download/v' .. version .. '/' .. asset,
  }
end

-- ---------------------------------------------------------------------------
-- SHA-256 and CRC-32
-- ---------------------------------------------------------------------------
local SHA_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Lowercase hex. Every word is masked to 32 bits: Lua integers are 64.
function M.sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  msg = msg .. '\128' .. string.rep('\0', (55 - len) % 64) .. string.pack('>I8', len * 8)
  local K, w, unpack = SHA_K, {}, string.unpack
  local FMT = '>I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4'
  for p = 1, #msg, 64 do
    w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14],
      w[15], w[16] = unpack(FMT, msg, p)
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = ((x >> 7 | x << 25) ~ (x >> 18 | x << 14) ~ (x >> 3)) & 0xffffffff
      local s1 = ((y >> 17 | y << 15) ~ (y >> 19 | y << 13) ~ (y >> 10)) & 0xffffffff
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = ((e >> 6 | e << 26) ~ (e >> 11 | e << 21) ~ (e >> 25 | e << 7)) & 0xffffffff
      local t1 = (h + S1 + ((e & f) ~ (~e & g)) + K[i] + w[i]) & 0xffffffff
      local S0 = ((a >> 2 | a << 30) ~ (a >> 13 | a << 19) ~ (a >> 22 | a << 10)) & 0xffffffff
      local t2 = (S0 + ((a & b) ~ (a & c) ~ (b & c))) & 0xffffffff
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff
    end
    h0, h1 = (h0 + a) & 0xffffffff, (h1 + b) & 0xffffffff
    h2, h3 = (h2 + c) & 0xffffffff, (h3 + d) & 0xffffffff
    h4, h5 = (h4 + e) & 0xffffffff, (h5 + f) & 0xffffffff
    h6, h7 = (h6 + g) & 0xffffffff, (h7 + h) & 0xffffffff
  end
  return string.format('%08x%08x%08x%08x%08x%08x%08x%08x', h0, h1, h2, h3, h4, h5, h6, h7)
end

local CRC
function M.crc32(s)
  if not CRC then
    CRC = {}
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
      end
      CRC[i] = c
    end
  end
  local t, byte, c, n = CRC, string.byte, 0xFFFFFFFF, #s
  for i = 1, n, 4096 do
    local chunk = { byte(s, i, math.min(i + 4095, n)) }
    for j = 1, #chunk do c = t[(c ~ chunk[j]) & 0xFF] ~ (c >> 8) end
  end
  return c ~ 0xFFFFFFFF
end

-- ---------------------------------------------------------------------------
-- Inflate (RFC 1951)
-- ---------------------------------------------------------------------------
local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
  67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
  4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
  769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
  9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- A decode table: every `maxLen`-bit value whose low bits are a code (read
-- least significant bit first) maps to symbol * 16 + code length.
local function huffTable(lengths, n)
  local count, maxLen = {}, 0
  for i = 0, 15 do count[i] = 0 end
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    count[l] = count[l] + 1
    if l > maxLen then maxLen = l end
  end
  count[0] = 0
  local code, nextCode = 0, {}
  for bits = 1, 15 do
    code = (code + count[bits - 1]) << 1
    nextCode[bits] = code
  end
  local t, size = {}, 1 << maxLen
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    if l > 0 then
      local c, r = nextCode[l], 0
      nextCode[l] = c + 1
      for _ = 1, l do r = (r << 1) | (c & 1); c = c >> 1 end
      local v = s * 16 + l
      for k = r, size - 1, 1 << l do t[k] = v end
    end
  end
  return t, maxLen
end

local FIXED
local function fixedTables()
  if not FIXED then
    local ll, dl = {}, {}
    for s = 0, 287 do
      ll[s] = (s < 144 and 8) or (s < 256 and 9) or (s < 280 and 7) or 8
    end
    for s = 0, 29 do dl[s] = 5 end
    local lt, lmax = huffTable(ll, 288)
    local dt, dmax = huffTable(dl, 30)
    FIXED = { lt, lmax, dt, dmax }
  end
  return FIXED[1], FIXED[2], FIXED[3], FIXED[4]
end

-- `expected` is the size the zip directory gives: the output is cut off past
-- it, so a damaged stream cannot grow without limit.
function M.inflate(src, expected)
  local byte, char = string.byte, string.char
  local srcLen = #src
  local pos, buf, cnt = 1, 0, 0
  local out, n = {}, 0
  local limit = (expected or M.MAX_ZIP) + 258

  local function bits(k)
    while cnt < k do
      if pos > srcLen + 4 then error('the data ends early', 0) end
      buf = buf | ((byte(src, pos) or 0) << cnt)
      pos, cnt = pos + 1, cnt + 8
    end
    local v = buf & ((1 << k) - 1)
    buf, cnt = buf >> k, cnt - k
    return v
  end

  local function decode(t, maxLen)
    while cnt < maxLen do
      if pos > srcLen + 4 then error('the data ends early', 0) end
      buf = buf | ((byte(src, pos) or 0) << cnt)
      pos, cnt = pos + 1, cnt + 8
    end
    local v = t[buf & ((1 << maxLen) - 1)]
    if not v then error('an invalid code', 0) end
    local l = v & 15
    buf, cnt = buf >> l, cnt - l
    return v >> 4
  end

  local function dynamicTables()
    local hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
    local cl = {}
    for i = 0, 18 do cl[i] = 0 end
    for i = 1, hclen do cl[CL_ORDER[i]] = bits(3) end
    local ct, cmax = huffTable(cl, 19)
    local lengths, i, total = {}, 0, hlit + hdist
    while i < total do
      local sym = decode(ct, cmax)
      if sym < 16 then
        lengths[i] = sym
        i = i + 1
      else
        local value, times = 0, 0
        if sym == 16 then
          if i == 0 then error('a repeat with nothing before it', 0) end
          value, times = lengths[i - 1], 3 + bits(2)
        elseif sym == 17 then
          times = 3 + bits(3)
        else
          times = 11 + bits(7)
        end
        if i + times > total then error('too many code lengths', 0) end
        for _ = 1, times do lengths[i] = value; i = i + 1 end
      end
    end
    local ll, dl = {}, {}
    for s = 0, hlit - 1 do ll[s] = lengths[s] end
    for s = 0, hdist - 1 do dl[s] = lengths[hlit + s] end
    if (ll[256] or 0) == 0 then error('no end-of-block code', 0) end
    local lt, lmax = huffTable(ll, hlit)
    local dt, dmax = huffTable(dl, hdist)
    return lt, lmax, dt, dmax
  end

  repeat
    local final = bits(1)
    local kind = bits(2)
    if kind == 0 then
      -- Stored: to the byte boundary, LEN and its complement, then the bytes.
      local drop = cnt & 7
      buf, cnt = buf >> drop, cnt - drop
      local len, nlen = bits(16), bits(16)
      if len ~ 0xFFFF ~= nlen then error('a stored block with a bad length', 0) end
      while len > 0 and cnt >= 8 do
        n = n + 1
        out[n] = buf & 0xFF
        buf, cnt, len = buf >> 8, cnt - 8, len - 1
      end
      if len > 0 then
        if pos + len - 1 > srcLen then error('a stored block runs past the end', 0) end
        local stop = pos + len - 1
        while pos <= stop do
          local chunk = { byte(src, pos, math.min(pos + 3999, stop)) }
          for k = 1, #chunk do out[n + k] = chunk[k] end
          n, pos = n + #chunk, pos + #chunk
        end
      end
      if n > limit then error('more data than the zip says', 0) end
    elseif kind == 1 or kind == 2 then
      local lt, lmax, dt, dmax
      if kind == 1 then lt, lmax, dt, dmax = fixedTables()
      else lt, lmax, dt, dmax = dynamicTables() end
      while true do
        local sym = decode(lt, lmax)
        if sym < 256 then
          n = n + 1
          out[n] = sym
        elseif sym == 256 then
          break
        else
          local li = sym - 256
          local len = LEN_BASE[li]
          if not len then error('an invalid length', 0) end
          if LEN_EXTRA[li] > 0 then len = len + bits(LEN_EXTRA[li]) end
          if dmax == 0 then error('a match with no distance codes', 0) end
          local d = decode(dt, dmax) + 1
          local dist = DIST_BASE[d]
          if not dist then error('an invalid distance', 0) end
          if DIST_EXTRA[d] > 0 then dist = dist + bits(DIST_EXTRA[d]) end
          if dist > n then error('a match from before the start', 0) end
          -- Overlap is allowed (a run): each byte is copied after the one it
          -- may come from.
          local from = n - dist
          for k = 1, len do out[n + k] = out[from + k] end
          n = n + len
          if n > limit then error('more data than the zip says', 0) end
        end
      end
    else
      error('an invalid block type', 0)
    end
  until final == 1

  local parts = {}
  for i = 1, n, 4096 do
    parts[#parts + 1] = char(table.unpack(out, i, math.min(i + 4095, n)))
  end
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Zips, held in memory
-- ---------------------------------------------------------------------------
-- { name, flags, method, crc, csize, usize, offset } for every entry, or nil
-- and why. ZIP64 is refused: a release is about a megabyte.
function M.zipEntries(data)
  local size = #data
  if size < 22 then return nil, 'too short to be a zip' end
  local eocd, from = nil, math.max(1, size - 22 - 65535 + 1)
  while true do
    local i = data:find('PK\5\6', from, true)
    if not i then break end
    eocd, from = i, i + 1
  end
  if not eocd or size - eocd + 1 < 22 then return nil, 'not a zip' end
  local count, cdSize, cdOffset = string.unpack('<I2I4I4', data, eocd + 10)
  if count == 0xFFFF or cdSize == 0xFFFFFFFF or cdOffset == 0xFFFFFFFF then
    return nil, 'a ZIP64 archive'
  end
  if cdOffset + cdSize > eocd - 1 then return nil, 'a zip whose directory is out of place' end
  local list, p = {}, cdOffset + 1
  for _ = 1, count do
    if p + 45 > size or data:sub(p, p + 3) ~= 'PK\1\2' then
      return nil, 'a zip with a damaged directory'
    end
    local flags, method, _, _, crc, csize, usize, nameLen, extraLen, commentLen =
      string.unpack('<I2I2I2I2I4I4I4I2I2I2', data, p + 8)
    local offset = string.unpack('<I4', data, p + 42)
    list[#list + 1] = {
      name = data:sub(p + 46, p + 45 + nameLen), flags = flags, method = method,
      crc = crc, csize = csize, usize = usize, offset = offset,
    }
    p = p + 46 + nameLen + extraLen + commentLen
  end
  return list
end

-- One entry's bytes, unpacked and checked against its CRC-32.
function M.zipRead(data, e)
  local p = e.offset + 1
  if data:sub(p, p + 3) ~= 'PK\3\4' then return nil, e.name .. ' is damaged' end
  if e.flags & 1 == 1 then return nil, e.name .. ' is encrypted' end
  if e.usize > M.MAX_ZIP then return nil, e.name .. ' is too big' end
  local nameLen, extraLen = string.unpack('<I2I2', data, p + 26)
  local start = p + 30 + nameLen + extraLen
  local raw = data:sub(start, start + e.csize - 1)
  if #raw ~= e.csize then return nil, e.name .. ' is cut short' end
  local out = raw
  if e.method == 8 then
    local ok, res = pcall(M.inflate, raw, e.usize)
    if not ok then return nil, e.name .. ' does not unpack: ' .. tostring(res) end
    out = res
  elseif e.method ~= 0 then
    return nil, e.name .. ' uses a compression this cannot read'
  end
  if #out ~= e.usize or M.crc32(out) ~= e.crc then
    return nil, e.name .. ' fails its checksum'
  end
  return out
end

-- The client zip must carry the extension and its loader at its ROOT: a zip
-- with an extra folder level mounts and loads nothing.
local CLIENT_MUST = {
  'lua/ge/extensions/raceManager.lua',
  'scripts/raceManager/modScript.lua',
  'ui/modules/apps/RaceManager/app.js',
}

-- A release zip, unpacked and checked. Returns { client = bytes, server = {
-- [name] = bytes } } or nil and why. STRICT: a path this does not know where
-- to put stops the update, rather than installing half a release. Root files
-- (LICENSE) are not installed, as with a hand install.
function M.unpackRelease(data, version)
  local entries, err = M.zipEntries(data)
  if not entries then return nil, 'the download is ' .. err end
  local files = { server = {} }
  for _, e in ipairs(entries) do
    local name = e.name
    local plugin = name:match('^Server/RaceManager/([%w_%-]+%.lua)$')
    if name:sub(-1) == '/' then
      -- A folder entry.
    elseif name == 'Client/RaceManager.zip' or plugin then
      local bytes, why = M.zipRead(data, e)
      if not bytes then return nil, why end
      if plugin then files.server[plugin] = bytes else files.client = bytes end
    elseif name:find('/', 1, true) then
      return nil, 'the release has ' .. tostring(M.cleanText(name, 80))
        .. ', which this updater does not know where to put. Install it by hand'
    end
  end
  if not files.client then return nil, 'the release has no Client/RaceManager.zip' end
  local main = files.server['main.lua']
  if not main then return nil, 'the release has no Server/RaceManager/main.lua' end
  local stamp = main:match("\nlocal RM_BUILD = '([^']+)'")
  if stamp ~= version then
    return nil, 'the release says v' .. version .. ' but its main.lua is build '
      .. tostring(M.cleanText(tostring(stamp), 20))
  end
  -- Compiled, never run: a file over Lua's 200-local limit, or written for a
  -- newer Lua, fails here instead of leaving the server without the plugin.
  for name, src in pairs(files.server) do
    local fn, why = load(src, '=' .. name, 't', {})
    if not fn then return nil, name .. ' in the release does not compile: ' .. tostring(why) end
  end
  local inner, why = M.zipEntries(files.client)
  if not inner then return nil, 'Client/RaceManager.zip is ' .. why end
  local have = {}
  for _, e in ipairs(inner) do have[e.name] = true end
  for _, must in ipairs(CLIENT_MUST) do
    if not have[must] then return nil, 'Client/RaceManager.zip has no ' .. must end
  end
  return files
end

-- ---------------------------------------------------------------------------
-- Background downloads
-- ---------------------------------------------------------------------------
-- A download runs in a process of its own and leaves a .done file holding its
-- exit code, polled from the tick: the Lua state never waits on the network.
-- On Windows it goes through Start-Process for the reason in maps.lua: a child
-- started any other way keeps the server's UDP socket.
local function batQuote(s) return (tostring(s):gsub('%%', '%%%%')) end
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

local function abs(p)
  if p:match('^%a:') or p:sub(1, 1) == '/' then return p end
  return M.cwd() .. '/' .. p
end

-- curl ships with Windows 10 and later; on Linux, curl or else wget. Only
-- checked strings reach these lines: the URL is built from a validated repo
-- and version, and every path hangs off the server's own folder.
function M.jobScript(job)
  local ua = 'PhoenixRaceManager/' .. tostring(host and host.RM_BUILD or '0')
  local header = job.api and 'Accept: application/vnd.github+json' or nil
  if IS_WINDOWS then
    return table.concat({
      '@echo off',
      'rem Written by Race Manager to ' .. job.purpose .. '. Safe to delete.',
      'cd /d "' .. batQuote(native(job.cwd)) .. '"',
      '"%SystemRoot%\\System32\\curl.exe" -fsSL --connect-timeout 15 --max-time ' .. job.seconds
        .. ' -A "' .. ua .. '"' .. (header and (' -H "' .. header .. '"') or '')
        .. ' -o "' .. batQuote(native(job.outAbs)) .. '" "' .. job.url .. '" 2>"'
        .. batQuote(native(job.errAbs)) .. '"',
      '>"' .. batQuote(native(job.doneAbs)) .. '" echo %errorlevel%',
      '',
    }, '\r\n')
  end
  return table.concat({
    '#!/bin/bash',
    '# Written by Race Manager to ' .. job.purpose .. '. Safe to delete.',
    -- The server's sockets, closed: see the relaunch helper in maps.lua.
    'if [ -n "$BASH_VERSION" ]; then',
    '  for fd in /proc/$$/fd/*; do n=${fd##*/}',
    '    case $n in 0|1|2|255) ;; *) eval "exec $n>&-" ;; esac',
    '  done 2>/dev/null',
    'fi',
    'cd ' .. shQuote(job.cwd) .. ' || exit 1',
    'if command -v curl >/dev/null 2>&1; then',
    '  curl -fsSL --connect-timeout 15 --max-time ' .. job.seconds .. ' -A ' .. shQuote(ua)
      .. (header and (' -H ' .. shQuote(header)) or '') .. ' -o ' .. shQuote(job.outAbs)
      .. ' ' .. shQuote(job.url) .. ' 2>' .. shQuote(job.errAbs),
    'else',
    '  wget -q -T ' .. job.seconds .. ' -U ' .. shQuote(ua)
      .. (header and (' --header=' .. shQuote(header)) or '') .. ' -O ' .. shQuote(job.outAbs)
      .. ' ' .. shQuote(job.url) .. ' 2>' .. shQuote(job.errAbs),
    'fi',
    'echo $? > ' .. shQuote(job.doneAbs),
    '',
  }, '\n')
end

function M.spawn(job)
  if not writeFile(at(job.script), M.jobScript(job)) then return false end
  local path, ok, res = abs(job.script)
  if IS_WINDOWS then
    ok, res = pcall(M.sys.execute, 'powershell -NoProfile -NonInteractive -Command "'
      .. 'Start-Process -FilePath ' .. psQuote(native(path))
      .. ' -WorkingDirectory ' .. psQuote(native(job.cwd)) .. ' -WindowStyle Hidden"')
  else
    ok, res = pcall(M.sys.execute, '(command -v bash >/dev/null && nohup bash ' .. shQuote(path)
      .. ' || nohup sh ' .. shQuote(path) .. ') > /dev/null 2>&1 < /dev/null &')
  end
  return ok and res == true
end

local timerOn, timerOff

-- { name, purpose, url, api, seconds, out, onDone }; onDone(path) or onDone(nil, why).
local function startJob(job)
  if M.job then return false, 'still waiting on GitHub from before' end
  local cwd = M.cwd()
  if not cwd then return false, 'could not tell which folder the server runs in' end
  local dir = workDir()
  host.makeDirectory(at(dir))
  job.cwd = cwd
  job.script = dir .. '/' .. job.name .. (IS_WINDOWS and '.cmd' or '.sh')
  job.outRel, job.errRel, job.doneRel = dir .. '/' .. job.out, dir .. '/' .. job.name .. '.err',
    dir .. '/' .. job.name .. '.done'
  job.outAbs, job.errAbs, job.doneAbs = abs(job.outRel), abs(job.errRel), abs(job.doneRel)
  for _, p in ipairs({ job.outRel, job.errRel, job.doneRel }) do removeFile(at(p)) end
  if not M.spawn(job) then return false, 'could not start the download' end
  job.started = os.time()
  M.job = job
  timerOn()
  return true
end

-- Why a download failed, from its exit code (curl's, or cmd's for a missing
-- curl.exe) and what it wrote to stderr.
function M.downloadError(code, stderr)
  local why = ({
    [6]    = 'could not look up GitHub (is the server offline?)',
    [7]    = 'could not connect to GitHub',
    [22]   = 'GitHub refused the request',
    [28]   = 'GitHub took too long to answer',
    [35]   = 'the secure connection to GitHub failed',
    [60]   = 'the secure connection to GitHub failed (certificates)',
    [127]  = 'neither curl nor wget is installed on this server',
    [9009] = 'curl.exe is missing (Windows 10 1803 and later include it)',
  })[code] or ('the download failed (code ' .. tostring(code) .. ')')
  local http = type(stderr) == 'string' and stderr:match('error: (%d%d%d)')
  if http then why = why .. ' (HTTP ' .. http .. ')' end
  if http == '403' or http == '429' then
    why = why .. '. GitHub limits how often one address may ask: try again in an hour'
  end
  return why
end

local function pollJob()
  local job = M.job
  if not job then return end
  local text = readFile(at(job.doneRel))
  local code = text and tonumber(text:match('%d+'))
  if not code then
    if os.time() - job.started <= job.seconds + 30 then return end
    M.job = nil
    return job.onDone(nil, 'no answer after ' .. (job.seconds + 30) .. ' seconds')
  end
  M.job = nil
  local err = readFile(at(job.errRel))
  for _, p in ipairs({ job.script, job.errRel, job.doneRel }) do removeFile(at(p)) end
  if code ~= 0 then
    removeFile(at(job.outRel))
    return job.onDone(nil, M.downloadError(code, err))
  end
  return job.onDone(at(job.outRel))
end

-- ---------------------------------------------------------------------------
-- State to the admins
-- ---------------------------------------------------------------------------
-- It rides each admin's own RM_Update (main.lua's targeted push), not an event
-- of its own: a client binds its server events once per game session, so one
-- added in this release would not reach an admin who rejoined after updating.
local function push()
  if host and host.pushAdmins then pcall(host.pushAdmins) end
end

function M.snapshot(pid)
  local r, s = M.release, M.state
  local latest = r.latest
  local busy = host.busy()
  return {
    current    = host.RM_BUILD,
    enabled    = cfg('updateCheck', true) ~= false,
    checking   = M.job ~= nil and M.job.name == 'check' or M.pendingCheck,
    checkedAt  = r.at,
    checkError = r.error,
    latest     = latest and latest.version or nil,
    available  = latest ~= nil and M.newer(latest.version, host.RM_BUILD),
    title      = latest and latest.title or nil,
    notes      = latest and latest.notes or nil,
    url        = latest and latest.url or nil,
    size       = latest and latest.size or nil,
    phase      = s.phase,
    target     = s.target and s.target.version or nil,
    left       = s.left,
    by         = s.by,
    note       = s.note,
    error      = M.lastError,
    last       = M.last,
    busy       = busy,
    -- The admin tier's alone, like the other commands with no undo.
    canUpdate  = host.isFull(pid) == true,
  }
end

-- A refusal: a toast to whoever asked, and the reason on the Admin tab.
local function tell(pid, msg)
  MP.TriggerClientEvent(pid, 'RM_Notice', Util.JsonEncode({
    kind = 'session', msg = 'Update', sub = msg,
  }))
  M.lastError = msg
  push()
end

-- ---------------------------------------------------------------------------
-- The clock
-- ---------------------------------------------------------------------------
-- One timer for the check, the download and the countdown. BeamMP starts a
-- second timer if the same name is created twice, and the countdown would run
-- at double speed.
timerOn = function ()
  if M.ticking then return end
  M.ticking = true
  MP.CreateEventTimer('RM_UpdateTick', 1000)
end

timerOff = function ()
  if not M.ticking then return end
  M.ticking = false
  MP.CancelEventTimer('RM_UpdateTick')
end

local function settle()
  local p = M.state.phase
  if not M.job and not M.pendingCheck and (p == 'idle' or p == 'downloading') then
    timerOff()
  end
end

local function reset()
  M.state = { phase = 'idle' }
  settle()
end

local function fail(msg)
  local v = M.state.target and M.state.target.version
  print('[RaceManager] Update' .. (v and (' to v' .. v) or '') .. ' stopped: ' .. msg)
  M.lastError = msg
  reset()
  push()
end

-- ---------------------------------------------------------------------------
-- Asking GitHub
-- ---------------------------------------------------------------------------
local function checked(path, err, repo)
  local r = M.release
  r.at = os.time()
  if not path then
    r.error = err
    print('[RaceManager] Could not check for an update: ' .. err)
    return push()
  end
  local text = readFile(path)
  removeFile(path)
  local ok, data = pcall(host.jsonParse, text or '')
  local rel, why = M.readRelease(ok and data or nil, repo)
  if not rel then
    r.error = why
    print('[RaceManager] Could not check for an update: ' .. why)
    return push()
  end
  r.error, r.latest = nil, rel
  if M.newer(rel.version, host.RM_BUILD) then
    print(string.format('[RaceManager] Phoenix Race Manager v%s is out (this server runs %s). '
      .. 'An admin can install it from the Admin tab: Update and restart.', rel.version, host.RM_BUILD))
  else
    print('[RaceManager] Phoenix Race Manager is up to date (' .. host.RM_BUILD .. ')')
  end
  push()
end

-- One request to the GitHub API. Unauthenticated, so GitHub allows 60 an hour
-- from one address: once a boot, and on an admin's request.
function M.startCheck(why)
  if cfg('updateCheck', true) == false then return false, 'update checks are off' end
  local repo = cfg('updateRepo', M.REPO)
  if not M.validRepo(repo) then
    M.release.error = 'updateRepo in config.json is not owner/name'
    return false, M.release.error
  end
  local ok, err = startJob({
    name = 'check', purpose = 'look for a new release', api = true,
    seconds = M.CHECK_SECONDS, out = 'latest.json',
    url = 'https://api.github.com/repos/' .. repo .. '/releases/latest',
    onDone = function (path, e) checked(path, e, repo) end,
  })
  if not ok then
    M.release.error = err
    push()
    return false, err
  end
  print('[RaceManager] Asking GitHub for the newest Phoenix Race Manager (' .. why .. ')')
  push()
  return true
end

-- ---------------------------------------------------------------------------
-- The update
-- ---------------------------------------------------------------------------
local function kickEveryone()
  local reason = 'Race Manager: the server is restarting to update Phoenix Race Manager. '
    .. 'Rejoin in about a minute.'
  for pid in pairs(MP.GetPlayers() or {}) do
    if MP.DropPlayer then pcall(MP.DropPlayer, pid, reason) end
  end
end

local function fetched(path, err)
  local s = M.state
  if s.phase ~= 'downloading' then
    if path then removeFile(path) end
    return settle()
  end
  if not path then return fail('The download failed: ' .. err .. '. Nothing was changed.') end
  local rel = s.target
  s.phase = 'verifying'
  push()
  local clock = os.clock()
  local data = readFile(path)
  removeFile(path)
  if not data or #data ~= rel.size then
    return fail('The download is ' .. tostring(data and #data or 0) .. ' bytes, not the '
      .. rel.size .. ' GitHub lists. Nothing was changed.')
  end
  if M.sha256(data) ~= rel.digest then
    return fail('The download does not match the SHA-256 GitHub lists for it. Nothing was changed.')
  end
  local files, why = M.unpackRelease(data, rel.version)
  if not files then return fail(why:gsub('^%l', string.upper) .. '. Nothing was changed.') end
  local busy = host.busy()
  if busy then return fail('Not while ' .. busy .. '. Press Update again after it.') end
  local n = 0
  for _ in pairs(files.server) do n = n + 1 end
  print(string.format('[RaceManager] Update v%s downloaded and checked in %.1fs: '
    .. 'the client zip and %d plugin files', rel.version, os.clock() - clock, n))
  s.files = files
  s.phase, s.left = 'countdown', M.COUNTDOWN
  MP.SendChatMessage(-1, string.format('[RaceManager] Updating Phoenix Race Manager to v%s (%s). '
    .. 'Everyone is disconnected in %d seconds and the server restarts.', rel.version, s.by, M.COUNTDOWN))
  host.notifyField('session', 'Server update',
    'The server restarts in ' .. M.COUNTDOWN .. ' seconds to update Phoenix Race Manager. '
      .. 'Rejoin in about a minute.')
  timerOn()
  push()
end

function M.start(pid, raw)
  if not host.requireFull(pid) then return end
  local ok, data = pcall(host.jsonParse, raw or '')
  local want = ok and type(data) == 'table' and data.version or nil
  local rel = M.release.latest
  if M.state.phase ~= 'idle' then return tell(pid, 'An update is already under way.') end
  if not rel or not M.newer(rel.version, host.RM_BUILD) then
    return tell(pid, 'There is no newer release to install.')
  end
  if want ~= rel.version then
    return tell(pid, 'The newest release is now v' .. rel.version .. '. Look at it, then press Update again.')
  end
  local busy = host.busy()
  if busy then return tell(pid, 'Not while ' .. busy .. ': end it first.') end
  if M.job then return tell(pid, 'Still waiting on GitHub. Try again in a moment.') end
  local restart = host.restart
  if not restart then
    return tell(pid, 'maps.lua did not load, so the server cannot restart itself. Install v'
      .. rel.version .. ' by hand: ' .. rel.url)
  end
  -- Decided before anything is downloaded: a server that cannot restart itself
  -- would be left running the old plugin beside the new files.
  local info = restart.probe()
  local method, _, note = restart.resolve(info, true)
  if method ~= 'relaunch' and method ~= 'exit' then
    local why = cfg('mapRestart', 'auto') == 'manual'
      and 'Restarts are set to manual (mapRestart in config.json).'
      or (note or 'This server cannot restart itself.')
    return tell(pid, why .. ' Install v' .. rel.version .. ' by hand: ' .. rel.url)
  end
  local by = MP.GetPlayerName(pid) or ('player ' .. pid)
  M.lastError = nil
  M.state = { phase = 'downloading', target = rel, by = by, probe = info, method = method,
    note = note }
  local started, err = startJob({
    name = 'fetch', purpose = 'download Phoenix Race Manager v' .. rel.version,
    seconds = M.FETCH_SECONDS, out = rel.asset .. '.part', url = rel.download,
    onDone = fetched,
  })
  if not started then return fail('Could not start the download: ' .. err .. '.') end
  print(string.format('[RaceManager] Update to v%s started by %s (%s, parent %s, pid %s)',
    rel.version, by, method, tostring(info.parent), tostring(info.pid)))
  push()
end

-- Either tier may stop one: that direction is always safe.
function M.cancel(pid)
  if not host.requireAuth(pid) then return end
  local s = M.state
  if s.phase ~= 'downloading' and s.phase ~= 'verifying' and s.phase ~= 'countdown' then
    return push()
  end
  local counting = s.phase == 'countdown'
  print('[RaceManager] Update to v' .. s.target.version .. ' stopped by '
    .. (MP.GetPlayerName(pid) or pid))
  M.lastError = nil
  reset()
  if counting then
    host.notifyField('session', 'Server update cancelled', 'The server keeps running')
  end
  push()
end

-- Every file the release replaces, backed up first and put back if any write
-- fails. Plugin .lua files the release no longer has are moved out too: BeamMP
-- runs every .lua in the folder. Data/ is never touched; it is not in a release.
function M.apply(files, version)
  local plugin, client = M.paths.plugin, clientDir()
  if not exists(at(plugin .. '/main.lua')) then
    return false, plugin .. ' has no main.lua, so it is not the plugin. Nothing was changed.'
  end
  local attic = M.paths.attic .. '/update-' .. host.RM_BUILD .. '-to-' .. version .. '_'
    .. os.date('%Y-%m-%d_%H-%M-%S')
  local plan = { { path = client .. '/RaceManager.zip', new = files.client,
    backup = attic .. '/Client/RaceManager.zip' } }
  -- Case-blind: on Windows Main.lua IS main.lua, and "removing" it would
  -- delete the file just written.
  local names, shipped = {}, {}
  for name in pairs(files.server) do
    names[#names + 1] = name
    shipped[name:lower()] = true
  end
  local listed, found = pcall(host.listDirectory, at(plugin))
  for _, name in ipairs(listed and found or {}) do
    if name:lower():match('%.lua$') and not shipped[name:lower()] then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    plan[#plan + 1] = { path = plugin .. '/' .. name, new = files.server[name],
      backup = attic .. '/Server/RaceManager/' .. name }
  end

  host.makeDirectory(at(attic .. '/Client'))
  host.makeDirectory(at(attic .. '/Server/RaceManager'))
  for _, p in ipairs(plan) do
    p.old = readFile(at(p.path)) or false
    if p.old and not writeFile(at(p.backup), p.old) then
      return false, 'Could not back up ' .. p.path .. ' into ' .. attic .. '. Nothing was changed.'
    end
  end

  for i, p in ipairs(plan) do
    local ok
    if p.new then ok = writeFile(at(p.path), p.new) else ok = removeFile(at(p.path)) end
    if not ok then
      local lost = {}
      for j = i, 1, -1 do
        local q = plan[j]
        local back
        if q.old then back = writeFile(at(q.path), q.old) else back = removeFile(at(q.path)) end
        if not back then lost[#lost + 1] = q.path end
      end
      if #lost == 0 then
        return false, 'Could not write ' .. p.path .. ', so everything was put back as it was.'
      end
      return false, 'Could not write ' .. p.path .. ', and ' .. table.concat(lost, ', ')
        .. ' could not be put back: copy them from ' .. attic .. ' before restarting.'
    end
  end

  host.makeDirectory(at(workDir()))
  writeFile(at(workDir() .. '/last.json'), host.jsonStringify({
    from = host.RM_BUILD, to = version, at = os.time(), by = M.state.by, attic = attic,
  }))
  print('[RaceManager] Update to v' .. version .. ' installed; the old files are in ' .. attic)
  return true
end

-- At zero plus the settle: the restart helper first, so a server that could
-- not get one is left exactly as it was, then the files, then the stop.
function M.execute()
  local s = M.state
  s.phase = 'applying'
  local version = s.target.version
  if s.method == 'relaunch' and not host.restart.spawnRelauncher(s.probe) then
    return fail('Could not start the helper that restarts the server. Nothing was changed: '
      .. 'players can rejoin.')
  end
  local ok, err = M.apply(s.files, version)
  s.files = nil
  if not ok then return fail(err) end
  host.restart.stopServer('updating Phoenix Race Manager to v' .. version)
end

function M.tick()
  local before = M.state.phase
  pollJob()
  if M.pendingCheck and not M.job then
    M.pendingCheck = false
    M.startCheck('startup')
  end
  local s = M.state
  -- A download that just finished starts its countdown on the NEXT tick, or
  -- the field gets a second less warning than it was told.
  if s.phase ~= before then return end
  if s.phase == 'countdown' then
    s.left = s.left - 1
    if s.left == 5 then
      host.notifyField('session', 'Server update', 'Everyone is disconnected in 5 seconds')
    end
    if s.left > 0 then return push() end
    local busy = host.busy()
    if busy then return fail('Stopped: ' .. busy .. '. Nothing was changed.') end
    s.phase, s.left = 'kicking', M.SETTLE
    kickEveryone()
    return
  elseif s.phase == 'kicking' then
    s.left = s.left - 1
    if s.left > 0 then return end
    return M.execute()
  end
  settle()
end

-- Joining between the kick and the stop would download a client zip the
-- server is about to replace.
function M.onPlayerAuth()
  local p = M.state.phase
  if p == 'kicking' or p == 'applying' then
    return 'The server is updating Phoenix Race Manager. Try again in a minute.'
  end
end

-- An admin logging in on a server that has been up for days gets a fresh look.
function M.onLogin()
  if M.job or M.pendingCheck or M.state.phase ~= 'idle' then return end
  local r = M.release
  if r.at and os.time() - r.at < M.RECHECK then return end
  M.startCheck('an admin logged in')
end

-- An update or its countdown, for maps.lua: one restart at a time.
function M.underWay()
  return M.state.phase ~= 'idle'
end

-- At boot: did the last update take, then clear what the jobs left and look
-- for a newer release. The record is KEPT and marked read, not deleted: the
-- old process can hot-reload the new files in its last second, and that
-- reload must not swallow the line the restarted server shows.
function M.warm()
  local dir = workDir()
  local listed, found = pcall(host.listDirectory, at(dir))
  for _, name in ipairs(listed and found or {}) do
    if name ~= 'last.json' then removeFile(at(dir .. '/' .. name)) end
  end
  local text = readFile(at(dir .. '/last.json'))
  local ok, rec = pcall(host.jsonParse, text or '')
  if ok and type(rec) == 'table' and type(rec.to) == 'string' then
    if rec.ok == nil then
      rec.ok = rec.to == host.RM_BUILD
      if rec.ok then
        print('[RaceManager] Update from ' .. tostring(rec.from) .. ' to ' .. rec.to .. ' complete')
      else
        print('[RaceManager] Update to ' .. rec.to .. ' did not take: this is ' .. host.RM_BUILD
          .. '. The previous files are in ' .. tostring(rec.attic))
      end
      writeFile(at(dir .. '/last.json'), host.jsonStringify(rec))
    end
    M.last = {
      ok = rec.ok == true, from = M.cleanText(rec.from, 20), to = M.cleanText(rec.to, 20),
      at = tonumber(rec.at), by = M.cleanText(rec.by, 40), attic = M.cleanText(rec.attic, 200),
    }
  end
  if cfg('updateCheck', true) ~= false then
    M.pendingCheck = true
    timerOn()
  end
end

-- The RM_Update* globals, installed here and not at file scope: see the top.
function M.init(h)
  host = h
  M.host = h
  function RM_onUpdateCheck(pid)
    if not host.requireAuth(pid) then return end
    if M.job or M.pendingCheck then return push() end
    local ok, err = M.startCheck('asked by ' .. (MP.GetPlayerName(pid) or pid))
    if not ok then tell(pid, 'Could not check: ' .. err .. '.') end
  end
  function RM_onUpdateStart(pid, raw) M.start(pid, raw) end
  function RM_onUpdateCancel(pid) M.cancel(pid) end
  function RM_UpdateTick() M.tick() end
  function RM_Update_onPlayerAuth() return M.onPlayerAuth() end
end

return M
