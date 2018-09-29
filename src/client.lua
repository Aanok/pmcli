-- module
local pmcli = {}

-- class
-- we init some "static" values
local PMCLI = {
  VERSION = "0.1",
  HELP_TEXT = [[Usage:
  pmcli [ --login ] [ --config configuration_file ]
  pmcli [ --help ] ]],
  AMBIGUOUS_CONTEXTS = {
    ["On Deck"] = true,
    ["Recently Added"] = true,
    ["Recently Aired"] = true,
    ["Recently Viewed Episodes"] = true
  }
}


-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- html entities (escape sequences)
local html_entities = require("htmlEntities")

-- JSON parsing
local json = require("dkjson").use_lpeg()

-- our own utils
local utils = require("pmcli.utils")

-- mpv IPC
local socket = require("cqueues.socket")

-- to drive mpv in parallel
local thread = require("cqueues.thread")

-- HTTP URL escaping
local http_encode = require("http.util").encodeURIComponent
-- ==============================


-- ========== CONVENIENCIES ==========
function pmcli.compute_title(item, parent_item)
  if item.title and item.title ~= "" then
    -- title field is filled, use it
    -- this should mean there is, generally speaking, available metadata
    if item.type == "episode" then
      -- for tv shows we want to show information on show title, season and episode number
      if PMCLI.AMBIGUOUS_CONTEXTS[html_entities.decode(parent_item.title2)] and item.grandparentTitle and item.index and item.parentIndex then
        -- menus where there is a jumble of shows and episodes, so we must show everything
        return string.format("%s S%02dE%02d - %s",
                            html_entities.decode(item.grandparentTitle),
                            item.parentIndex,
                            item.index,
                            html_entities.decode(item.title))
      elseif parent_item.mixedParents and item.index and item.parentIndex then
        -- mixedParents marks a generic promiscuous context, but we ruled out cases where shows are mixed
        -- so we only need season and episode
        return string.format("S%02dE%02d - %s", item.parentIndex, item.index, html_entities.decode(item.title))
      elseif item.index then
        -- here we should be in a specific season, so we only need the episode
        return string.format("E%02d - %s", item.index, html_entities.decode(item.title))
      end
    elseif item.type == "movie" and item.year then
      -- add year
      return string.format("%s (%d)", html_entities.decode(item.title), item.year)
    elseif item.type == "album" and parent_item.mixedParents and item.parentTitle then
      -- prefix with artist name
      return string.format("%s - %s", html_entities.decode(item.parentTitle), html_entities.decode(item.title))
    elseif item.type == "track" and parent_item.mixedParents and item.grandparentTitle and item.parentTitle then
      -- prefix with artist name and album
      return string.format("%s - %s - %s",
                          html_entities.decode(item.grandparentTitle),
                          html_entities.decode(item.parentTitle),
                          html_entities.decode(item.title))
    end
    -- no need for or availability of further information
    return html_entities.decode(item.title)
  elseif item.Media and item.Media[1].Part[1] then
    -- infer title from corresponding filename, like POSIX basename util
    return string.match(html_entities.decode(item.Media[1].Part[1].file), ".*/(.*)%..*")
  end
  -- either malformed item table or no media file to infer from
  return "Unknown title"
end
-- ===================================


-- ========== SETUP ==========
-- constructor
function pmcli.new(args)
  io.stdout:write("Plex Media CLIent v" ..  PMCLI.VERSION .. "\n")
  local self = {}
  setmetatable(self, { __index = PMCLI })
  
  -- first, read CLI arguments
  local parsed_args = self:parse_args(args)
  
  -- setup options from config file
  -- or, alternatively, ask user and login
  local error_message, error_code
  self.options, error_message, error_code = utils.get_config(parsed_args.config_filename)
  if not self.options and error_code == 2 then
    -- config file not found
    -- if --login was passed, skip confirmation prompt
    self.options = self:first_time_config(parsed_args.login, parsed_args.config_filename)
  elseif not self.options and error_code ~= 2 then
    -- real error
    self:quit("Error opening configuration file:\n" .. error_message)
  elseif self.options and parsed_args.login then
    -- config file found but user wants to redo login
    io.stdout:write("Attempting new login to obtain a new token.\n")
    self.options.plex_token, self.options.unique_identifier = self:login()
    io.stdout:write("Committing configuration to disk...\n")
    
    local ok, error_message, error_code = utils.write_config(self.options, parsed_args.config_filename)
    if not ok and error_code == -2 then
      io.stderr:write(error_message .. "\n")
    elseif not ok and error_code ~= -2 then
      self:quit("Error writing configuration file:\n" .. error_message)
    end
  end
  
  -- if we need to step around mismatched hostnames from the certificate
  local http_tls = require("http.tls")
  http_tls.has_hostname_validation = self.options.require_hostname_validation
  self.ssl_context = http_tls.new_client_context()
  
  -- if we need to skip certificate validation
  if not self.options.verify_server_certificates then
    self.ssl_context:setVerify(require("openssl.ssl.context").VERIFY_NONE)
  end
  
  -- IPC socket
  self.mpv_socket_name = os.tmpname()
  socket.settimeout(10.0) -- new default
  
  return self
end


function PMCLI:connect_mpv_socket()
  self.mpv_socket = socket.connect({ path = self.mpv_socket_name })
  --self.mpv_socket:settimeout(10.0)
end


-- command line arguments
function PMCLI:parse_args(args)
  local parsed_args = {}
  local i = 1
  while i <= #args do
    if args[i] == "--login" then
      parsed_args.login = true
    elseif args[i] == "--help" then
      io.stdout:write(PMCLI.HELP_TEXT .. "\n")
      self:quit()
    elseif args[i] == "--config" then
      -- next argument should be parameter
      if not args[i + 1] then
        self:quit("--config requires a filename.")
      end
      parsed_args.config_filename = args[i + 1]
      i = i + 1
    else
      self:quit("Unrecognized command line option: " .. args[i] .. "\n" .. PMCLI.HELP_TEXT)
    end
    i = i + 1
  end
  return parsed_args
end


-- headers for auth access
function PMCLI:setup_headers(headers)
  headers:append("x-plex-client-identifier", self.options.unique_identifier)
  headers:append("x-plex-product", "pmcli")
  headers:append("x-plex-version", PMCLI.VERSION)
  headers:append("x-plex-token", self.options.plex_token, true)
  headers:append("accept", "application/json")
end


function PMCLI:login()
  local plex_token
  local unique_identifier = "pmcli-" .. PMCLI.VERSION .. "-" .. utils.generate_random_id()
  repeat 
    io.stdout:write("\nPlease enter your Plex account name or email.\n")
    local login = utils.read()
    io.stdout:write("\nPlease enter your Plex account password.\n")
    local password, errmsg = utils.read_password()
    if not password then
      self:quit(errmsg)
    end
    plex_token, errmsg = self:request_token(login, password, unique_identifier)
    if not plex_token then
      io.stderr:write("[!!] Authentication error:\n", errmsg .. "\n")
      if not utils.confirm_yn("Would you like to try again with new credentials?") then
        self:quit("Configuration was unsuccessful.")
      end
    end
  until plex_token
  -- delete password from process memory as soon as possible
  password = nil
  collectgarbage()
  return plex_token, unique_identifier
end


function PMCLI:first_time_config(skip_prompt, user_filename)
  if not skip_prompt and not utils.confirm_yn("\nConfiguration file not found. Would you like to proceed with configuration and login?") then
    self:quit()
  end
  
  local options = {}
  
  local uri_patt = require("lpeg_patterns.uri").uri * -1
  io.stdout:write("\nPlease enter an address (and port if not default) to access your Plex Media Server.\nIt should look like https://example.com:32400 .\n")
  repeat
    options.base_addr = utils.read()
    if not uri_patt:match(options.base_addr) then
      io.stderr:write("[!!] Malformed URI. Please try again.\n")
    end
  until uri_patt:match(options.base_addr)
  
  options.plex_token, options.unique_identifier = self:login()
  
  options.require_hostname_validation = not utils.confirm_yn("\nDo you need PMCLI to ignore hostname validation (must e.g. if using builtin SSL certificate)?")
  
  io.stdout:write("\nCommitting configuration to disk...\n")
  local ok, error_message, error_code = utils.write_config(options, user_filename)
  if not ok and error_code == -2 then
    io.stderr:write(error_message .. "\n")
  elseif not ok and error_code ~= -2 then
    self:quit("Error writing configuration file:\n" .. error_message)
  end
  
  return options
end


-- token request
function PMCLI:request_token(login, pass, id)
  local request = http_request.new_from_uri("https://plex.tv/users/sign_in.json")
  request.headers:append("x-plex-client-identifier", id)
  request.headers:append("x-plex-product", "pmcli")
  request.headers:append("x-plex-version", PMCLI.VERSION)
  request.headers:delete(":method")
  request.headers:append(":method", "POST")
  request.headers:append("content-type", "application/x-www-form-urlencoded")
  request.headers:append("accept", "application/json")
  request:set_body("user%5blogin%5d=" .. http_encode(login) .. "&user%5bpassword%5d=" .. http_encode(pass))
  local headers, stream = request:go()
  if not headers then
    self:quit("Network error on token request: " .. stream)
  end
  local reply = json.decode(stream:get_body_as_string())
  if reply.error then
    return nil, reply.error
  else
    return reply.user.authentication_token
  end
end
-- ===========================


-- ========== FUNCTIONS ==========
function PMCLI:quit(error_message)
  if self.mpv_socket_name then os.remove(self.mpv_socket_name) end
  os.execute("stty " .. utils.stty_save) -- in case of fatal errors while mpv is running
  if error_message then
    io.stderr:write("[!!!] " .. error_message ..  "\n")
    os.exit(1)
  else
    os.exit(0)
  end
end


function PMCLI:plex_request(suffix)
  local request = http_request.new_from_uri(self.options.base_addr ..  suffix)
  request.ctx = self.ssl_context
  self:setup_headers(request.headers)
  local headers, stream = request:go(10.0) -- 10 secs timeout
  if not headers then
    -- timeout or other network error of sorts
    return nil, "Network error on API request " .. self.options.base_addr .. suffix .. ":\n" .. stream
  end
  if headers:get(":status") == "200" then
    return stream:get_body_as_string()
  elseif headers:get(":status") == "401" then
    return nil, "API request " .. self.options.base_addr .. suffix .. " returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login."
  else
    return nil, "API request " .. self.options.base_addr .. suffix .. " returned error " .. headers:get(":status") .. "."
  end
end


function PMCLI:sync_progress(item, msecs)
  if item.duration and item.rating_key then
  -- rating_key should always be there tbh, but duration might actually miss if
  -- a metadata update is in progress or such
    if not item.last_sync or item.last_sync ~= msecs then
    -- there is actual progress to update
      if msecs > item.duration * 0.95 then -- close enough to end, scrobble
        local ok, error_msg = self:plex_request("/:/scrobble?key=" .. item.rating_key .. "&identifier=com.plexapp.plugins.library")
        if not ok then
          io.stderr:write("[!] " .. error_msg .. "\n")
        else
          item.last_sync = nil
        end
      elseif msecs > item.duration * 0.05 then -- far enough from start, update viewOffset
        local ok, error_msg = self:plex_request("/:/progress?key=" .. item.rating_key .. "&time=" .. msecs .. "&identifier=com.plexapp.plugins.library")
        if not ok then
          io.stderr:write("[!] " .. error_msg .. "\n")
        else
          item.last_sync = msecs
        end
      end
    end
  end
  return item
end


function PMCLI:mpv_socket_handle(item)
  repeat
    local msg, err = self.mpv_socket:read()
    if msg == nil and err == 110 then
      -- timeout
      self.mpv_socket:clearerr()
      self.mpv_socket:write('{ "command": ["get_property", "playback-time"] }\n')
    elseif msg then
      local decoded = json.decode(msg)
      if decoded.data then -- reply to playback-time request
        item = self:sync_progress(item, math.floor(decoded.data*1000))
      end
    end
  until msg == nil and err ~= 110 -- TODO: handle this
  self.mpv_socket:clearerr()
end


function PMCLI:play_media(item)
-- this whole mechanism is a mess. look into something better.
  local mpv_args = "--input-ipc-server=" .. self.mpv_socket_name
  if item.view_offset and utils.confirm_yn("The item is set as partially viewed. Would you like to resume at " .. utils.msecs_to_time(item.view_offset) .. "?") then
    mpv_args = mpv_args .. " --start=" .. utils.msecs_to_time(item.view_offset)
  end
  mpv_args = mpv_args .. " " .. '--title="' .. item.title .. '"'
  mpv_args = mpv_args .. " --http-header-fields='X-Plex-Token: " .. self.options.plex_token .. "'"
  
  -- subs for video
  if item.subs then
    for _,s in ipairs(item.subs) do
      mpv_args = mpv_args .. " --sub-file=" .. s
    end
  end
  -- one part for video, many for audio playlist
  for _,k in ipairs(item.part_keys) do
    mpv_args = mpv_args .. " " .. self.options.base_addr .. k
  end
  
  -- run mpv SYNCHRONOUSLY in its own thread
  local mpv_thread = thread.start(function(con, mpv_args)
    -- signals are blocked by default in new threads, so we unblock SIGINT
    -- note that execute puts mpv in the foreground, so the main thread
    -- does not receive signals anymore
    local signal = require("cqueues.signal")
    signal.unblock(signal.SIGINT)
    os.execute("mpv " .. mpv_args)
  end, mpv_args)
  
  -- wait for mpv to setup the socket
  -- we will persevere for as long as mpv is running
  self:connect_mpv_socket()
  local joined = mpv_thread:join(0.5) -- if things go smooth this is enough
  while not self.mpv_socket:peername() and not joined do
    joined = mpv_thread:join(5.0) -- if there's a problem, we give it a lot of time
  end
  
  if joined then
    io.stderr:write("[!] Couldn't reach IPC socket, playback progress was not synced to Plex server.\n")
  else
    self:mpv_socket_handle(item)
  end

  -- innocuous if already joined
  mpv_thread:join()
end


function PMCLI:get_menu_items(reply, parent_key)
  local mc = reply.MediaContainer
  if not mc or not mc.title1 then
    return nil, "Unexpected reply to API request " .. self.options.base_addr .. parent_key .. ":\n" .. utils.tostring(reply, true)
  end
  
  local items = {}
  
  -- libraries and relevant views (All, By Album etc.)
  if mc.Directory then
    for i = 1,#mc.Directory do
      local item = mc.Directory[i]
      items[#items + 1] = {
        title = pmcli.compute_title(item, mc),
        key = utils.join_keys(parent_key, item.key),
      }
      if item.search then
        items[#items].tag = "?"
      else
        items[#items].tag = "L"
      end
    end
  end
  -- actual items
  if mc.Metadata then
    for i = 1,#mc.Metadata do
      local item = mc.Metadata[i]
      if item.type == "track" then
      -- audio: ready for streaming
        items[#items + 1] = {
          title = pmcli.compute_title(item, mc),
          duration = item.duration,
          view_offset = item.viewOffset,
          rating_key = item.ratingKey,
          part_keys = { utils.join_keys(parent_key, item.Media[1].Part[1].key) },
          tag = "T"
        }
      elseif item.type == "episode" or item.type == "movie" then
      -- video: will require fetching metadata before streaming
        items[#items + 1] = {
          title = pmcli.compute_title(item, mc),
          key = item.key,
          tag = item.type:sub(1,1):upper() -- E, M
        }
      else
      -- some kind of directory; NB this includes when type is nil which, afaik, is only for folders in "By Folder" view
        items[#items + 1] = {
          title = pmcli.compute_title(item, mc),
          key = item.key,
          tag = "D"
        }
      end
    end
  end

  -- section title
  if mc.title2 then
    items.title = html_entities.decode(mc.title1) ..  " - " .. html_entities.decode(mc.title2)
  else
    items.title = html_entities.decode(mc.title1)
  end
  
  -- will determine if "0: .." or "0: quit"
  items.is_root = mc.viewGroup == nil
  return items
end


function PMCLI:open_item(item)
  if item.tag == "D" or item.tag == "L" then
    self:open_menu(item)
  elseif item.tag == "T" then
    self:play_audio(item)
  elseif item.tag == "M" or item.tag == "E" then
    self:play_video(item)
  elseif item.tag == "?" then
    self:local_search(item)
  end
end


-- PLACEHOLDER!!
function PMCLI:play_audio(item)
  self:play_media(item)
end


function PMCLI:play_video(item)
  -- fetch metadata
  local body = assert(self:plex_request(item.key))
  local reply = assert(json.decode(body))
  body = nil
  local metadata = assert(reply.MediaContainer and reply.MediaContainer.Metadata and reply.MediaContainer.Metadata[1],
                          "Unexpected reply to API request " .. self.options.base_addr .. item.key)
  reply = nil
  
  -- check if there are multiple versions for the requested item
  local choice = 1
  if #(metadata.Media) > 1 then
    -- there are multiple versions and the user must choose
    io.stdout:write("\nThere are multiple versions for " .. item.title .. ":\n")
    for i,m in ipairs(metadata.Media) do
      local width = m.width or "unknown width "
      local height = m.height or "unkown height "
      local video_codec = m.videoCodec or "unknown codec"
      local audio_channels = m.audioChannels or "unknown"
      local audio_codec = m.audioCodec or "unknown codec"
      local bitrate = m.bitrate and m.bitrate .. "kbps" or "unknown bitrate"
      io.stdout:write(i .. ": " .. width .. "x" .. height .. " " .. video_codec .. ", " ..  audio_channels .. " channel " .. audio_codec .. ", " .. bitrate .. "\n")
    end
    -- user choice
    io.stdout:write("Please select one for playback: ")
    repeat
      choice = tonumber(utils.read())
      if not choice or choice < 1 or choice > #(metadata.Media) then
        io.stderr:write("[!!] Invalid choice.\n")
      end
    until choice and choice > 0  and choice <= #(metadata.Media)
  end
  
  -- all parts, each with their respective subtitles, are sent for playback
  for _,p in ipairs(metadata.Media[choice].Part) do
    local stream_item = {
      title = item.title,
      view_offset = metadata.viewOffset,
      duration = metadata.duration,
      rating_key = metadata.ratingKey,
      part_keys = { p.key },
      subs = { }
    }
    for _,s in ipairs(p.Stream) do
      if s.streamType == 3 and s.key then
        -- it's an external subtitle
        table.insert(stream_item.subs, self.options.base_addr .. s.key)
      end
    end
    self:play_media(stream_item)
  end
end


function PMCLI:local_search(search_item)
  io.stdout:write("Query? > ");
  local query = "&query=" .. http_encode(io.read())
  search_item.key = search_item.key .. query
  self:open_menu(search_item)
end


function PMCLI:open_menu(parent_item)
  while true do
    local body = assert(self:plex_request(parent_item.key))
    local reply = assert(json.decode(body), "Malformed JSON reply to request " .. self.options.base_addr .. parent_item.key ..":\n" .. body)
    body = nil
    local items = assert(self:get_menu_items(reply, parent_item.key))
    reply = nil
    utils.print_menu(items)
    for _,c in ipairs(utils.read_commands()) do
        if c == "q" then
          self:quit()
        elseif c == "*" then
          for _,item in ipairs(items) do
            self:open_item(item)
          end
        elseif c == 0 then
          return
        elseif c > 0 and c <= #items then
          self:open_item(items[c])
        end
    end
  end
end
-- ===============================


function PMCLI:run()
  io.stdout:write("Connecting to Plex Server...\n")
  local _, errmsg = pcall(self.open_menu, self, { key = "/library/sections" })
  self:quit(errmsg)
end


return pmcli
