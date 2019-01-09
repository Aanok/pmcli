-- module
local utils = {}

local lpeg = require("lpeg")

-- ========== COMMAND PARSER ===========
function utils.expand_range(left, right)
  local range = {}
  local step = left <= right and 1 or -1
  for i = left,right,step do
    range[#range + 1] = i
  end
  return range
end


function utils.flatten(t)
  if type(t) ~= "table" then return { t } end
  local flat = {}
  for i = 1, #t do
    local t_i = utils.flatten(t[i])
    for j = 1, #t_i do
      flat[#flat + 1] = t_i[j]
    end
  end
  return flat
end


--[[
Command GRAMMAR in (extended) BNF:
  S ::= "q" | "*" | I
  I ::= num L | R L
  L ::= "," I | ""
  R ::= num "-" num
  num ::= [0-9]+
  
Then there's provisions for whitespace.
]]--
utils.command_list = lpeg.Ct({
  lpeg.V("ws") * (lpeg.C("q") + lpeg.C("*") + lpeg.V("I")) * -1,
  I = lpeg.V("R") * lpeg.V("L") + lpeg.V("n") * lpeg.V("L"),
  L = lpeg.V("ws") * (lpeg.P(",") * lpeg.V("I") + lpeg.P("")),
  R = lpeg.V("n") * lpeg.V("dash") * lpeg.V("n") / utils.expand_range,
  dash = lpeg.V("ws") * lpeg.P("-"),
  n = lpeg.V("ws") * (lpeg.R("09")^1 / tonumber),
  ws = lpeg.P(lpeg.locale().space^0)
}) / utils.flatten


function utils.read_commands()
  local commands = utils.command_list:match(utils.read())
  while not commands do
    io.stderr:write("[!!] Malformed command string, please try again.\n")
    commands = utils.command_list:match(utils.read())
  end
  return commands
end

-- =====================================


-- ========== MISCELLANEOUS ==========
-- save stty state as we found it
function utils.save_stty()
  f = assert(io.popen("stty --save", "r"))
  s = assert(f:read())
  assert(f:close())
  return s
end


utils.stty_save = utils.save_stty()


function utils.escape_quote(str)
  return string.gsub(str, "'", "'\\''")
end


function utils.generate_random_id(len)
  math.randomseed(os.time())
  local id = {}
  for i = 1, len or 32 do
    id[#id +1] = math.random(0,9)
  end
  return table.concat(id)
end


function utils.msecs_to_time(ms)
  return os.date("%T", math.floor(ms/1000) - 3600) -- H:M:S, epoch was at 1AM
end


function utils.join_keys(s1, s2)
  -- special case: for playlist items we must replace everything
  if string.match(s1, "playlists/") then
    return s2
  end
  -- normal: concatenate but do not repeat overlap  (s1 suffix, s2 prefix)
  local i = 0
  local match_length = -1
  -- preprocessing: remove leading /
  if s1:sub(1,1) == "/" then s1 = s1:sub(2) end
  if s2:sub(1,1) == "/" then s2 = s2:sub(2) end
  for i = 1, math.min(#s1, #s2) do
    if s1:sub(1,i) == s2:sub(1,i) then
      match_length = i
    elseif match_length ~= -1 then
      -- there's been a match before, so that was the overlap
      break
    end
  end
  if match_length == -1 then
    return "/" .. s1 .. "/" .. s2
  elseif match_length == #s2 then
    return "/" .. s2
  else
    return "/" .. s1:sub(1, match_length) .. s2:sub(match_length + 1)
  end
end
-- ===================================


-- ========== IO ==========
function utils.confirm_yn(msg, default)
  io.stdout:write(msg .. " [y/n]\n")
  local yn = utils.read()
  while yn ~= "y" and yn ~= "n" do
    io.stderr:write("[!!] Please enter either 'y' or 'n'.\n")
    yn = utils.read()
  end
  return yn == "y"
end


function utils.read(mode)
  io.stdout:write("> ")
  return io.read(mode and mode or "*l")
end


function utils.read_utf8_char(file)
  local len = 1
  local char = file:read(1)
  if not char then return nil end
  local first_byte = string.byte(char)
  while (first_byte >= 192) do -- first two bits are 11
    first_byte = (first_byte * 2) % 2^8 -- shift left one bit
    len = len + 1
    char = char .. file:read(1)
  end
  return char, len
end


function utils.read_password()
  local pass = ""
  local len = 0
  local prev_len, ch
  os.execute("stty -echo raw")
  io.stdout:write("> ")
  repeat
    prev_len = len
    ch, len = utils.read_utf8_char(io.stdin)
    if ch == "\127" then -- backspace
      io.stdout:write("\b \b") -- go back, write whitespace, go back again
      io.stdout:flush()
      pass = pass:sub(1, -1 -prev_len) -- eat last character, which could be multiple bytes
    elseif ch == "\n" or ch == "\r" then -- EOL
      io.stdout:write("\n\r") -- accept EOL as end of string
      io.stdout:flush()
    elseif not ch then -- some IO error has occurred
      os.execute("stty " .. utils.stty_save)
      return nil, "Error while reading character from stdin."
    else -- valid character. mind it's a... wide definition of valid. like, Meta+F1 is valid.
      io.stdout:write("*")
      io.stdout:flush()
      pass = pass .. ch
    end
  until ch == '\n' or ch == '\r'
  os.execute("stty " .. utils.stty_save)
  return pass
end


function utils.indent(tt, times)
  for i = 1,times do
    tt[#tt + 1] = " "
  end
  return tt
end


-- tostring extension that can also work on tables
-- heavily based on code from http://lua-users.org/wiki/TableSerialization :)
function utils.tostring(tt, inline, indent, done)
  local sep = inline and " " or "\n"
  indent = indent or 0
  done = done or {} -- for cycle breaking
  if type(tt) == "table" then
    local sb = {}
    sb = utils.indent(sb, indent)
    sb[#sb + 1] = "{" .. sep
    indent = not inline and indent + 2 or 0
    for key, value in pairs (tt) do
      if type(value) == "table" and not done[value] then
        done[value] = true
        sb[#sb + 1] = utils.tostring(value, inline, indent, done)
      elseif "number" == type(key) then
        sb = utils.indent(sb, indent)
        sb[#sb + 1] = string.format("\"%s\"", tostring(value))
      else
        sb = utils.indent(sb, indent)
        sb[#sb + 1] = string.format("%s = \"%s\"", tostring(key), tostring(value))
      end
      sb[#sb + 1] = "," .. sep
    end
    if sb[#sb] == "," .. sep then
      sb[#sb] = sep
    end
    sb = utils.indent(sb, indent - 2)
    sb[#sb + 1] = "}"
    return table.concat(sb)
  else
    return tostring(tt)
  end
end
-- ========================


-- ========== CONFIG FILE ===========
function utils.parse_config_line(line)
  -- comments
  if string.match(line, '^#') then return nil end
  -- proper lines
  local key, value = string.match(line,'^%s-([^=%s]+)%s-=%s-([^%s]+)%s-$')
  -- recognize booleans
  if value == "true" then
    value = true
  elseif value == "false" then
    value = false
  end
  return key, value
end


function utils.get_config_absolute_filename()
  local dir = os.getenv("XDG_CONFIG_HOME")
  dir = dir or (os.getenv("HOME") and os.getenv("HOME") .. "/.config")
  if not dir then
    return nil, "specify a configuration file location by --config or either $XDG_CONFIG_HOME or $HOME need to be set"
  else
    return dir .. "/pmcli_config"
  end
end


function utils.write_config(options, user_filename)
  local config_filename, error_message = user_filename or utils.get_config_absolute_filename()
  if not config_filename then
    -- file not found of sorts
    return nil, error_message, -1
  end
  local file, error_message, error_code = io.open(config_filename, "w")
  if not file then
    -- error when opening
    return file, error_message, error_code
  end
  for k,v in pairs(options) do
    file:write(tostring(k) .. " = " .. tostring(v) .. "\n")
  end
  file:close()
  
  if not os.execute("chmod 600 " .. config_filename) then
    return nil, "Error setting 600 permissions to " .. config_filename .. ", you may want to double-check", -2
  else
    return true
  end
end


function utils.get_config(user_filename)
  -- defaults
  local options = {
    require_hostname_validation = true,
    verify_server_certificates = true,
    unique_identifier = "pmcli-dummy"
  }
    
  -- open file
  local config_filename, error_message = user_filename or utils.get_config_absolute_filename()
  if not config_filename then
    return nil, error_message
  end
  local file, error_message, error_code = io.open(config_filename)
  if not file then -- config file not found or other error
    return nil, error_message, error_code
  end
  
  -- parse file
  for line in file:lines() do
    local key, value = utils.parse_config_line(line)
    if key ~= nil and value ~= nil then options[key] = value end
  end

  file:close()  
  return options
end
-- ==================================

return utils