local PMCLI_VERSION = 0.1

local html_entities = require "htmlEntities"
local https = require "ssl.https"
local xml2lua = require "xml2lua"

local HANDLER_OPTS = { noreduce = { Directory = true, Track = true }}

local handler = require "xmlhandler.tree"
handler.options = HANDLER_OPTS
local parser = xml2lua.parser(handler)

local BASE_ADDR = "https://192.168.1.29:32400"


function plex_request(suffix)
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
  print("=== " .. handler.root.MediaContainer._attr.title1 .. " ===")
  if is_root == false then print("0: ..") end
  for _,mc in pairs(handler.root.MediaContainer) do
    for i,d in ipairs(mc) do
      if d._attr and d._attr.title then
        print(i .. ": " .. html_entities.decode(d._attr.title))
      end
    end
  end
end


function join_keys(s1, s2)
  local i = 0
  local match_length = -1
  print(s1 .. " vs " .. s2)
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


function open_menu(key, is_root)
  local command = -1
  local mc
  while command ~= 0 do
    print("in open_menu, key: " .. key)
    handler = handler:new()
    handler.options = HANDLER_OPTS
    parser = xml2lua.parser(handler)
    parser:parse(plex_request(key))
    mc = handler.root.MediaContainer
    print_current_menu(is_root)
    command = io.read("*number")
    if command ~= 0 then
      if mc.Directory ~= nil then
        open_menu(join_keys(key, mc.Directory[command]._attr.key), false)
      elseif mc.Track ~= nil then
        local media = plex_request(join_keys(key, mc.Track[command].Media.Part._attr.key))
        play_stream(media)
      elseif mc.Video ~= nil then
        local media = plex_request(join_keys(key, mc.Video[command].Media.Part._attr.key))
        play_stream(media)
      end
    end
  end
end




print("Plex Media CLIent v" ..  PMCLI_VERSION .. "\n")
open_menu("/library/sections", true)
--open_menu("/library/metadata/81774/children", false)
print("Bye!")