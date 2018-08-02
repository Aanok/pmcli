-- module
local utils = {}

local lpeg = require("lpeg")

-- ========== COMMAND PARSER ===========
function utils.expand_range(left, right)
  print(left,right)
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


-- ========== CONFIG FILE ===========
function utils.read_config_line(line)
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


function utils.get_config()
  -- figure out configuration file directory
  local dir = os.getenv("XDG_CONFIG_HOME")
  dir = dir or (os.getenv("HOME") and os.getenv("HOME") .. "/.config")
  
  -- defaults
  local options = {
      require_hostname_validation = true,
      unique_identifier = "temp_dummy" -- FIXME! generate some UUID and write to config file
    }
    
  -- load from file
  local file, e = io.open( dir .. "/pmcli_config")
  if not file then
    print(e)
    print("Please generate config file " .. dir .. "/pmcli_config as instructed on GitHub.")
    os.exit()
  end
  
  for line in file:lines() do
    local key, value = utils.read_config_line(line)
    if key ~= nil and value ~= nil then options[key] = value end
  end
  
  file:close()
  
  return options
end
-- ==================================

return utils