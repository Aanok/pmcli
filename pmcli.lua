#!/usr/bin/env lua
-- TODO: any sort of error handling. Like, at all.

PMCLI_VERSION = 0.1

BASE_ADDR = "https://192.168.1.29:32400"

html_entities = require "htmlEntities"
https = require "ssl.https"
xml2lua = require "xml2lua"

HANDLER_OPTS = { noreduce = { Directory = true, Track = true }}

handler = require "xmlhandler.tree"
handler.options = HANDLER_OPTS
parser = xml2lua.parser(handler)


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


function get_menu_items()
  local items = {}
  for child_name, child in pairs(handler.root.MediaContainer) do
    for i,item in pairs(child) do
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
  if is_root == false then
    print("0: ..") 
  else
    print("0: quit")
  end
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
        local media = plex_request(join_keys(key, items[c].Media.Part._attr.key))
        play_stream(media)
      end
    end
  end
end




print("Plex Media CLIent v" ..  PMCLI_VERSION .. "\n")
open_menu("/library/sections", true)
print("Bye!")