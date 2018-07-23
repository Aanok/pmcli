#!/usr/bin/env lua
-- TODO: any sort of error handling. Like, at all.

local PMCLI_VERSION = "0.2"


-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- html entities (escape sequences)
local html_entities = require("htmlEntities")

-- xml parsing
local xml2lua = require("xml2lua")
local HANDLER_OPTS = { noreduce = { Directory = true, Track = true, Video = true }}
local handler = require("xmlhandler.tree")
handler.options = HANDLER_OPTS
local parser = xml2lua.parser(handler)
-- ==============================


-- ========== SETUP ==========
-- config file shenanigans
local options = (function ()
  local dir = os.getenv("XDG_CONFIG_HOME")
  dir = dir or (os.getenv("HOME") and os.getenv("HOME") .. "/.config")
  dir = dir or "/etc"
  options = {
    require_hostname_validation = true,
    unique_identifier = "pmcli-" .. PMCLI_VERSION .. "-" .. (function()
      local f = io.popen("/bin/hostname")
      local hostname = f:read("*a") or "dummy"
      f:close()
      hostname = string.gsub(hostname, "\n$", "")
      return hostname
    end)()
  }
  local ok, e = pcall(dofile, dir .. "/pmcli_config.lua")
  if not ok then
    print(e)
    print("Please generate a config file as " .. dir .. "/pmcli_config.lua as instructed on GitHub.")
    os.exit()
  end
  return options
end)()


-- if we need to step around mismatched hostnames from the certificate
-- function to setup keeping a clean environment
local ssl_context = (function()
  local http_tls = require("http.tls")
  http_tls.has_hostname_validation = options.require_hostname_validation
  return http_tls.new_client_context()
end)()


-- headers for auth access
function setup_headers(headers)
  --headers:append("X-Plex-Client-Identifier", options.unique_identifier)
  --headers:append("X-Plex-Product", "PMCLI")
  --headers:append("X-Plex-Version", PMCLI_VERSION)
  headers:append("X-Plex-Token", options.plex_token, true)
end
-- ===========================


-- ========== FUNCTIONS ==========
function plex_request(suffix)
-- TODO: error handling
  local request = http_request.new_from_uri(options.base_addr .. suffix)
  request.ctx = ssl_context
  setup_headers(request.headers)
  local headers, stream = request:go()
  return stream:get_body_as_string()
end


function play_media(suffix)
  os.execute("mpv " ..  options.base_addr .. suffix .. "?X-Plex-Token=" .. options.plex_token)
end


function get_menu_items()
  local items = {}
  for child_name, child in pairs(handler.root.MediaContainer) do
    for _,item in pairs(child) do
      if item._attr and item._attr.title then
        item._tag = child_name
        items[#items + 1] = item
      end
    end
  end
  items._menu_title = handler.root.MediaContainer._attr.title1
  return items
end


function print_menu(items, is_root)
  print("=== " .. html_entities.decode(items._menu_title) .. " ===")
  print(is_root and "0: quit" or "0: ..")
  for i,item in ipairs(items) do
    print(item._tag:sub(1,1) .. " " .. i .. ": " .. html_entities.decode(item._attr.title))
  end
end


function join_keys(s1, s2)
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


function read_commands()
-- well formed string: 2,3-12,14,16,18-20 etc (, and - where - has precedence)
-- TODO: replace this embarrassing mess for something that can properly error on malformed strings
-- maybe use LPeg
  local commands = {}
  local iter = {}
  local n
  local input = io.read()
  if input ~= nil then
    if input == "q" then
      return { "q" }
    end
    for ranges in input:gmatch("[^,]+") do
      if ranges:find("%d+%s*-%s*%d+") then
        iter = ranges:gmatch("[^-]+")
        low, high = tonumber(iter()), tonumber(iter())
        for n = low, high do
          commands[#commands + 1] = n
        end
      else
        n = ranges:gsub("%s+", "")
        commands[#commands + 1] = tonumber(n)
      end
    end
  end
  return commands
end


function open_menu(key, is_root)
-- TODO: rewrite to avoid recursion (so old handlers can go out of scope and be GC'd)
-- we'll need a stack of menu keys to know where to backtrack
  local items
  handler = handler:new()
  handler.options = HANDLER_OPTS
  parser = xml2lua.parser(handler)
  parser:parse(plex_request(key))
  items = get_menu_items()
  while true do
    print_menu(items, is_root)
    for _,c in ipairs(read_commands()) do
      if c == 0 then
        return
      elseif c == "q" then
        print("Bye!")
        os.exit()
      elseif items[c]._tag == "Directory" then
        open_menu(join_keys(key, items[c]._attr.key), false)
      elseif items[c]._tag == "Video" or items[c]._tag == "Track" then
        play_media(join_keys(key, items[c].Media.Part._attr.key))
      end
    end
  end
end
-- ===============================


-- ========== MAIN BODY ==========
print("Plex Media CLIent v" ..  PMCLI_VERSION .. "\n")
open_menu("/library/sections", true)
print("Bye!")
-- ===============================
