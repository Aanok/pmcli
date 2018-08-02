-- module
local pmcli = {}

-- class
-- we init some "static" values
local PMCLI = {
  VERSION = "0.1",
  HANDLER_OPTS = { noreduce = { Directory = true, Track = true, Video = true }}
}

-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- html entities (escape sequences)
local html_entities = require("htmlEntities")

-- xml parsing
local xml2lua = require("xml2lua")

-- our own utils
local utils = require("pmcli.utils")
-- ==============================


-- ========== SETUP ==========
-- constructor
function pmcli.new()
  local self = {}
  setmetatable(self, { __index = PMCLI })
  
  -- setup options from config file
  self.options = utils.get_config()
  require("pl.pretty").dump(self.options)
  
  -- if we need to step around mismatched hostnames from the certificate
  local http_tls = require("http.tls")
  http_tls.has_hostname_validation = self.options.require_hostname_validation
  self.ssl_context = http_tls.new_client_context()
  
  -- xml parsing shenanigans
  self.handler = require("xmlhandler.tree")
  self.handler.options = PMCLI.HANDLER_OPTS
  self.parser = xml2lua.parser(handler)
  
  return self
end


-- headers for auth access
function PMCLI:setup_headers(headers)
  --headers:append("X-Plex-Client-Identifier", options.unique_identifier)
  --headers:append("X-Plex-Product", "PMCLI")
  --headers:append("X-Plex-Version", PMCLI_VERSION)
  headers:append("X-Plex-Token", self.options.plex_token, true)
end
-- ===========================


-- ========== FUNCTIONS ==========
function PMCLI:plex_request(suffix)
-- TODO: error handling
  local request = http_request.new_from_uri(self.options.base_addr .. suffix)
  request.ctx = ssl_context
  self:setup_headers(request.headers)
  local headers, stream = request:go()
  print(headers, stream)
  return stream:get_body_as_string()
end


function PMCLI:play_media(suffix)
  os.execute("mpv " ..  self.options.base_addr .. suffix .. "?X-Plex-Token=" .. self.options.plex_token)
end


function PMCLI:get_menu_items()
  local items = {}
  for child_name, child in pairs(self.handler.root.MediaContainer) do
    for _,item in pairs(child) do
      if item._attr and item._attr.title then
        item._tag = child_name
        items[#items + 1] = item
      end
    end
  end
  items._menu_title = self.handler.root.MediaContainer._attr.title1
  return items
end


local function print_menu(items, is_root)
  print("=== " .. html_entities.decode(items._menu_title) .. " ===")
  print(is_root and "0: quit" or "0: ..")
  for i,item in ipairs(items) do
    print(item._tag:sub(1,1) .. " " .. i .. ": " .. html_entities.decode(item._attr.title))
  end
end


local function join_keys(s1, s2)
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


function PMCLI:open_menu(key, is_root)
-- TODO: rewrite to avoid recursion (so old handlers can go out of scope and be GC'd)
-- we'll need a stack of menu keys to know where to backtrack
  local items
  self.handler = self.handler:new()
  self.handler.options = HANDLER_OPTS
  self.parser = xml2lua.parser(self.handler)
  self.parser:parse(self:plex_request(key))
  items = self:get_menu_items()
  while true do
    print_menu(items, is_root)
    for _,c in ipairs(utils.read_commands()) do
      if c == 0 then
        return
      elseif c == "q" then
        print("Bye!")
        os.exit()
      elseif items[c]._tag == "Directory" then
        self:open_menu(join_keys(key, items[c]._attr.key), false)
      elseif items[c]._tag == "Video" or items[c]._tag == "Track" then
        self:play_media(join_keys(key, items[c].Media.Part._attr.key))
      end
    end
  end
end
-- ===============================


function PMCLI:run()
  print("Plex Media CLIent v" ..  self.VERSION .. "\n")
  self:open_menu("/library/sections", true)
  print("Bye!")
end


return pmcli