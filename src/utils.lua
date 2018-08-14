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
  for _,v1 in ipairs(t) do
    for _,v2 in ipairs(utils.flatten(v1)) do
      flat[#flat + 1] = v2
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
  local commands = utils.command_list:match(io.read())
  while not commands do
    print("[!] Malformed command string, please try again.")
    commands = utils.command_list:match(io.read())
  end
  return commands
end

-- =====================================


-- ========== MISCELLANEOUS ==========
function utils.generate_random_id()
  -- string of 32 random digits
  math.randomseed(os.time())
  local id = ""
  for i = 1,32 do
    id = id .. math.random(0,9)
  end
  return id
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
      os.execute("stty echo cooked")
      io.stderr:write("[!!!] Error while reading character from stdin.\n")
      os.exit(1)
    else -- valid character. mind it's a... wide definition of valid. like, Meta+F1 is valid.
      io.stdout:write("*")
      io.stdout:flush()
      pass = pass .. ch
    end
  until ch == '\n' or ch == '\r'
  os.execute("stty echo cooked")
  return pass
end
-- ===================================


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
    value= false
  end
  return key, value
end


function utils.get_config_absolute_filename()
  local dir = os.getenv("XDG_CONFIG_HOME")
  dir = dir or (os.getenv("HOME") and os.getenv("HOME") .. "/.config")
  return dir .. "/pmcli_config"
end


function utils.write_config(options)
  local file, e = io.open(utils.get_config_absolute_filename(), "w")
  if not file then
    io.stderr:write("[!!!] Error committing configuration to config file: ")
    io.stderr:write(e .. "\n")
    os.exit(1)
  end
  for k,v in pairs(options) do
    file:write(tostring(k) .. " = " .. tostring(v) .. "\n")
  end
  file:close()
end


function utils.get_config()
  -- defaults
  local options = {
    require_hostname_validation = true,
    verify_server_certificates = true,
    unique_identifier = "pmcli-dummy"
  }
    
  -- open file
  local file = io.open(utils.get_config_absolute_filename())
  if not file then -- config file not found
    return nil
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