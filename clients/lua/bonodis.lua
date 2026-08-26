-- Bonodis client for Lua 5.1+.
--
-- Two ways in:
--   1. Any Redis Lua library against RESP2 (--port, default 6379)
--      local redis = require "redis"; local c = redis.connect("127.0.0.1", 6379)
--   2. This module: HTTP JSON on --metrics-port, or raw RESP via LuaSocket.
--
--   local b = require("bonodis").http({ host = "127.0.0.1", port = 9090, auth = "secret" })
--   print(b:call("PING"))
--   b:call("SET", "k", "v")
--   print(b:call("GET", "k"))
--   print(b:call("EVAL", "return redis.call('GET', KEYS[1])", "1", "k"))

local M = {}

local function json_esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r")
  return s
end

local function encode_argv(argv)
  local parts = {}
  for i = 1, #argv do
    parts[#parts + 1] = "\"" .. json_esc(argv[i]) .. "\""
  end
  return "{\"argv\":[" .. table.concat(parts, ",") .. "]}"
end

local function http_post(host, port, path, body, auth)
  local http = require("socket.http")
  local ltn12 = require("ltn12")
  local headers = {
    ["content-type"] = "application/json",
    ["content-length"] = tostring(#body),
  }
  if auth and auth ~= "" then
    headers["x-bonodis-auth"] = auth
  end
  local chunks = {}
  local ok, code = http.request({
    url = string.format("http://%s:%d%s", host, port, path),
    method = "POST",
    headers = headers,
    source = ltn12.source.string(body),
    sink = ltn12.sink.table(chunks),
  })
  if not ok then
    return nil, tostring(code)
  end
  return table.concat(chunks), tonumber(code)
end

function M.http(opts)
  opts = opts or {}
  local host = opts.host or "127.0.0.1"
  local port = opts.port or 9090
  local auth = opts.auth
  local self = { host = host, port = port, auth = auth }
  function self:call(...)
    local argv = { ... }
    local body = encode_argv(argv)
    if auth then
      body = "{\"auth\":\"" .. json_esc(auth) .. "\",\"argv\":" .. body:match("%b[]") .. "}"
    end
    local raw, err = http_post(host, port, "/api", body, auth)
    if not raw then
      return nil, err
    end
    local result = raw:match("\"result\":%s*(.+)%s*%}$")
    if result then
      if result:sub(1, 1) == "\"" then
        return result:sub(2, -2):gsub("\\n", "\n"):gsub("\\\"", "\""):gsub("\\\\", "\\")
      end
      if result == "null" then
        return nil
      end
      return result
    end
    local errm = raw:match("\"error\":\"(.-)\"")
    return nil, errm or raw
  end
  function self:pipeline(commands)
    local buf = {"{\"commands\":["}
    for i, argv in ipairs(commands) do
      if i > 1 then
        buf[#buf + 1] = ","
      end
      buf[#buf + 1] = encode_argv(argv):match("%b[]")
    end
    buf[#buf + 1] = "]}"
    return http_post(host, port, "/api/pipeline", table.concat(buf), auth)
  end
  return self
end

-- Raw RESP2 over TCP (LuaSocket). Works against --port, not --metrics-port.
function M.resp_encode(argv)
  local t = { "*" .. tostring(#argv) .. "\r\n" }
  for i = 1, #argv do
    local a = tostring(argv[i])
    t[#t + 1] = "$" .. tostring(#a) .. "\r\n" .. a .. "\r\n"
  end
  return table.concat(t)
end

function M.resp(opts)
  opts = opts or {}
  local socket = require("socket")
  local host = opts.host or "127.0.0.1"
  local port = opts.port or 6379
  local sock, err = socket.connect(host, port)
  if not sock then
    return nil, err
  end
  sock:settimeout(opts.timeout or 3)
  local self = { sock = sock }
  function self:call(...)
    local n, e = sock:send(M.resp_encode({ ... }))
    if not n then
      return nil, e
    end
    return sock:receive("*l")
  end
  function self:close()
    sock:close()
  end
  return self
end

return M
