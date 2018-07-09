#!/usr/bin/env lua
-- TODO: any sort of error handling. Like, at all.

local PMCLI_VERSION = 0.1

local BASE_ADDR = "https://192.168.1.29:32400"

local html_entities = require "htmlEntities"
local https = require "ssl.https"
local xml2lua = require "xml2lua"

local HANDLER_OPTS = { noreduce = { Directory = true, Track = true }}

local handler = require "xmlhandler.tree"
handler.options = HANDLER_OPTS
local parser = xml2lua.parser(handler)


function plex_request(suffix)
  -- TODO: an async version so we can "stream" to mpv
  local body, code, headers, status = https.request(BASE_ADDR .. suffix)
  return body
end


function play_stream(stream)
  local tmp_filename = os.tmpname();
  local tmp_file = io.open(tmp_filename, "w+b")
  io.output(tmp_file)
  io.write(stream)
  io.close()
  io.output(io.stdout)
  os.execute("mpv " ..  tmp_filename)
  os.remove(tmp_filename)
end



function print_current_menu(is_root)
  print("=== " .. html_entities.decode(handler.root.MediaContainer._attr.title1) .. " ===")
  if is_root == false then
    print("0: ..") 
  else
    print("0: quit")
  end
  for tag,mc in pairs(handler.root.MediaContainer) do
    for i,d in ipairs(mc) do
      if d._attr and d._attr.title then
        print(tag:sub(1,1) .. " " .. i .. ": " .. html_entities.decode(d._attr.title))
      end
    end
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
  local commands = {}
  local iter = {}
  local n
  local input = io.read()
  if input ~= nil then
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
  local mc
  while true do
    handler = handler:new()
    handler.options = HANDLER_OPTS
    parser = xml2lua.parser(handler)
    parser:parse(plex_request(key))
    mc = handler.root.MediaContainer
    print_current_menu(is_root)
    for _,c in ipairs(read_commands()) do
      if c == 0 then
        return
      else
        if mc.Directory ~= nil then
          open_menu(join_keys(key, mc.Directory[c]._attr.key), false)
        elseif mc.Track ~= nil then
          local media = plex_request(join_keys(key, mc.Track[c].Media.Part._attr.key))
          play_stream(media)
        elseif mc.Video ~= nil then
          local media = plex_request(join_keys(key, mc.Video[c].Media.Part._attr.key))
          play_stream(media)
        end
      end
    end
  end
end




print("Plex Media CLIent v" ..  PMCLI_VERSION .. "\n")
open_menu("/library/sections", true)
print("Bye!")