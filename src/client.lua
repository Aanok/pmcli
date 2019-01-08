-- module
local pmcli = {}

-- class
-- we init some "static" values
local PMCLI = {
  VERSION = "0.1.4",
  HELP_TEXT = [[Usage:
  pmcli [ --login ] [ --config configuration_file ]
  pmcli [ --help ] ]],
  AMBIGUOUS_CONTEXTS = {
    ["On Deck"] = true,
    ["Recently Added"] = true,
    ["Recently Aired"] = true,
    ["Recently Viewed Episodes"] = true,
    ["Playlist"] = true
  },
  IPC = {
    GET_PLAYBACK_TIME = '{ "command": ["get_property", "playback-time"], "request_id": 1 }\n'
  },
  ROOT_MENU = [[

=== Plex Server ===
0. quit
L 1. Library Sections
L 2. Recently Added Content
L 3. On Deck Content
L 4. Playlists
]]
}


-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- our own utils
local utils = require("pmcli.utils")

-- in-memory XML parser
local lxp_lom = require("lxp.lom")

-- mpv IPC
local socket = require("cqueues.socket")

-- to drive mpv in parallel
local thread = require("cqueues.thread")

-- HTTP URL escaping
local http_encode = require("http.util").encodeURIComponent
-- ==============================


-- ========== CONVENIENCIES ==========
function pmcli.compute_title(item, media_container)
  if item.title and item.title ~= "" then
    -- title field is filled, use it
    -- this should mean there is, generally speaking, available metadata
    if item.type == "episode" then
      -- for tv shows we want to show information on show title, season and episode number
      if PMCLI.AMBIGUOUS_CONTEXTS[media_container.title2] and item.grandparent_title and item.index and item.parent_index then
        -- menus where there is a jumble of shows and episodes, so we must show everything
        return string.format("%s S%02dE%02d - %s",
                            item.grandparent_title,
                            item.parent_index,
                            item.index,
                            item.title)
      elseif media_container.mixed_parents and item.index and item.parent_index then
        -- mixedParents marks a generic promiscuous context, but we ruled out cases where shows are mixed
        -- so we only need season and episode
        return string.format("S%02dE%02d - %s", item.parent_index, item.index, item.title)
      elseif item.index then
        -- here we should be in a specific season, so we only need the episode
        return string.format("E%02d - %s", item.index, item.title)
      end
    elseif item.type == "movie" and item.year then
      -- add year
      return string.format("%s (%d)", item.title, item.year)
    elseif (item.type == "album" or item.type == "season") and media_container.mixed_parents and item.parent_title then
      -- artist - album / show - season
      return string.format("%s - %s", item.parent_title, item.title)
    elseif item.type == "track" and media_container.mixed_parents and item.grandparent_title and item.parent_title then
      -- prefix with artist name and album
      return string.format("%s - %s - %s",
                          item.grandparent_title,
                          item.parent_title,
                          item.title)
    end
    -- no need for or availability of further information
    return item.title
  elseif item.file then
    -- infer title from corresponding filename, like POSIX basename util
    return string.match(item.file, ".*/(.*)%..*")
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
  local must_save_config = false
  local error_message, error_code
  self.options, error_message, error_code = utils.get_config(parsed_args.config_filename)
  if not self.options and error_code == 2 then
    -- config file not found
    -- if --login was passed, skip confirmation prompt
    self.options = self:first_time_config(parsed_args.login, parsed_args.config_filename)
    must_save_config = true
  elseif not self.options and error_code ~= 2 then
    -- real error
    self:quit("Error opening configuration file:\n" .. error_message)
  end
  -- self.options is valid from here onwards
  
  if not self.options.pmcli_version or self.options.pmcli_version ~= PMCLI.VERSION then
    io.stdout:write("Check the changelog at https://github.com/Aanok/pmcli/blob/master/Changelog.md\n")
    self.options.pmcli_version = PMCLI.VERSION
    must_save_config = true
  end
  
  if parsed_args.login then
    -- config file found but user wants to redo login
    io.stdout:write("Attempting new login to obtain a new token.\n")
    self.options.plex_token, self.options.unique_identifier = self:login()
    must_save_config = true
  end
  
  if must_save_config then
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
  
  -- for tmp files we use a common suffix for tidyness' sake
  local tmpname = os.tmpname()
  os.remove(tmpname) -- it was touch'd to reserve it
  tmpname = tmpname .. "_pmcli"
  
  -- save HTTP replies locally
  self.stream_filename = tmpname .. "_stream"
  
  -- IPC socket
  self.mpv_socket_name = tmpname .. "_socket"
  socket.settimeout(10.0) -- new default
  
  -- parser
  self.sax = require("pmcli.sax")
  self.sax.init(tmpname .. "_header", tmpname .. "_body", self.stream_filename)
  
  return self
end


function PMCLI:connect_mpv_socket()
  self.mpv_socket = socket.connect({ path = self.mpv_socket_name })
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
end


function PMCLI:login()
  local plex_token
  local unique_identifier = "pmcli-" .. utils.generate_random_id()
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
      io.stderr:write("[!!] Authentication error: ", errmsg .. "\n")
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
  
  return options
end


-- token request
function PMCLI:request_token(login, pass, id)
  local request = http_request.new_from_uri("https://plex.tv/users/sign_in.xml")
  request.headers:upsert(":method", "POST")
  request.headers:append("content-type", "application/x-www-form-urlencoded")
  request.headers:append("x-plex-client-identifier", id)
  request.headers:append("x-plex-product", "pmcli")
  request.headers:append("x-plex-version", PMCLI.VERSION)
  request:set_body("user%5blogin%5d=" .. http_encode(login) .. "&user%5bpassword%5d=" .. http_encode(pass))
  local headers, stream = request:go()
  if not headers then
    self:quit("Network error on token request: " .. stream)
  end
  local reply = lxp_lom.parse(stream:get_body_as_string())
  if reply[2].tag == "error" then
    return nil, reply[2][1] -- error msg
  else
    return reply.attr.authentication_token
  end
end
-- ===========================


-- ========== MEMBERS ==========
function PMCLI:quit(error_message)
  if self.mpv_socket_name then os.remove(self.mpv_socket_name) end
  if self.sax then self.sax.destroy() end
  if self.stream_filename then os.remove(self.stream_filename) end
  os.execute("stty " .. utils.stty_save) -- in case of fatal errors while mpv is running
  if error_message then
    io.stderr:write("[!!!] " .. error_message ..  "\n")
    os.exit(1)
  else
    os.exit(0)
  end
end


function PMCLI:plex_request(suffix, to_file)
	local request = http_request.new_from_uri(self.options.base_addr ..  suffix)
	request.ctx = self.ssl_context
	self:setup_headers(request.headers)
	local headers, stream = request:go(20.0) -- 10 secs timeout
	if not headers then
		-- timeout or other network error of sorts
		return nil, "Network error on API request " .. self.options.base_addr .. suffix .. ":\n" .. stream
	end
	if headers:get(":status") == "200" then
		if to_file then
			self.stream_file_handle = io.open(self.stream_filename, "w")
			stream:save_body_to_file(self.stream_file_handle)
			self.stream_file_handle:close()
			return true
		else
			return stream:get_body_as_string()
		end
	elseif headers:get(":status") == "401" then
		return nil, "API request " .. self.options.base_addr .. suffix .. " returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login."
	else
		return nil, "API request " .. self.options.base_addr .. suffix .. " returned error " .. headers:get(":status") .. "."
	end
end


function PMCLI:sync_progress(item, msecs)
  if item.duration and item.rating_key then
  -- rating_key should always be there tbh, but duration might actually be missing if
  -- a metadata update is in progress or such
    if not item.last_sync or math.abs(item.last_sync - msecs) > 10000 then
    -- there is actual progress to update
      local total_msecs = item.offset_to_part + msecs
      if total_msecs > item.duration * 0.95 then -- close enough to end, scrobble
        local ok, error_msg = self:plex_request("/:/scrobble?key=" .. item.rating_key .. "&identifier=com.plexapp.plugins.library")
        if not ok then
          io.stderr:write("[!] " .. error_msg .. "\n")
        else
          item.last_sync = nil
        end
      elseif total_msecs > item.duration * 0.05 then -- far enough from start, update viewOffset
        local ok, error_msg = self:plex_request("/:/progress?key=" .. item.rating_key .. "&time=" .. total_msecs .. "&identifier=com.plexapp.plugins.library")
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


function PMCLI:mpv_socket_handle(playlist)
  local pos = 1
  local must_ask_offset = false
  local msg, err
  
  repeat
    msg, err = self.mpv_socket:read()
    if msg == nil and err == 110 then
      -- timeout
      self.mpv_socket:clearerr()
      self.mpv_socket:write(PMCLI.IPC.GET_PLAYBACK_TIME)
    elseif msg then
      local decoded = json.decode(msg)
      if decoded.event == "property-change" and decoded.id == 1 then
        -- playlist-pos-1
        pos = decoded.data
        if pos ~= 1 and playlist[pos].view_offset then
          -- there is a bookmark, so we must prompt the user about it
          -- but note: the first item's already been taken care of
          -- mpv's term-playing-msg, tracks and tags will be shown before the prompt
          self.mpv_socket:write('{ "command": ["set_property", "pause", true] }\n')
          must_ask_offset = true
        end
      elseif must_ask_offset and decoded.event == "pause" then
        -- mpv has written its header and is about to print term-status-msg
        -- which we don't want because it will interleave and overlap with our I/O
        -- so we disable mpv's terminal functionalities altogether (in,err,out)
        self.mpv_socket:write('{ "command": ["set_property", "terminal", false] }\n')
        local offset_time = utils.msecs_to_time(playlist[pos].view_offset)
        -- mpv disables tty echo and maybe other functionalities
        local mpv_stty = utils.save_stty()
        os.execute("stty " .. utils.stty_save)
        if utils.confirm_yn("\n" .. playlist[pos].title .. " is set as partially viewed. Would you like to resume at " .. offset_time .. "?") then
          self.mpv_socket:write(string.format('{ "command": ["seek", "%s"] }\n', offset_time))
        end
        io.stdout:write("\n")
        os.execute("stty " .. mpv_stty)
        must_ask_offset = false
        self.mpv_socket:write('{ "command": ["set_property", "terminal", true] }\n')
        self.mpv_socket:write('{ "command": ["set_property", "pause", false] }\n')
      elseif decoded.event == "seek" then
        self.mpv_socket:write(PMCLI.IPC.GET_PLAYBACK_TIME)
      elseif decoded.request_id == 1 and decoded.error == "success" then
        -- good reply to playback-time request
        item = self:sync_progress(playlist[pos], math.floor(decoded.data*1000))
      end
    end
  until msg == nil and err ~= 110
  return self.mpv_socket:eof(), err
end


function PMCLI:play_media(playlist, force_resume)
  local mpv_args = "--input-ipc-server=" .. self.mpv_socket_name  
  mpv_args = mpv_args .. " --http-header-fields='x-plex-token: " .. self.options.plex_token .. "'"
  mpv_args = mpv_args .. " --title='" .. utils.escape_quote(playlist[1].title) .. "'"
  
  -- bookmark
  if playlist[1].view_offset and (force_resume or utils.confirm_yn(playlist[1].title .. " is set as partially viewed. Would you like to resume at " .. utils.msecs_to_time(playlist[1].view_offset) .. "?")) then
    mpv_args = mpv_args .. " --start=" .. utils.msecs_to_time(playlist[1].view_offset)
  end
  
  -- subs for video
  if playlist[1].subs then
    for _,s in ipairs(playlist[1].subs) do
      mpv_args = mpv_args .. " --sub-file=" .. s
    end
  end
  
  -- parts
  for _,item in ipairs(playlist) do
    mpv_args = mpv_args .. " " .. self.options.base_addr .. item.part_key
  end
  
  -- notify user if running a playlist
  if #playlist > 1 then
    io.stdout:write("\n-- " .. #playlist .. " tracks have been gathered in an mpv playlist --\n\n")
  end
  
  -- run mpv SYNCHRONOUSLY in its own thread
  local mpv_thread = thread.start(function(con, mpv_args)
    -- signals are blocked by default in new threads, so we unblock SIGINT
    -- note that the main thread does not receive signals anymore as well
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
    -- request tracking for playlist's sake
    self.mpv_socket:write('{ "command": ["observe_property", 1, "playlist-pos-1"] }\n')
    local ok, err = self:mpv_socket_handle(playlist)
    if not ok then
      err = require("cqueues.errno").strerror(err)
      io.stderr:write("[!] IPC socket error: " .. err ..". Playback sync halted.\n" )
      -- TODO: improve this
    end
  end

  -- innocuous if already joined
  mpv_thread:join()
end


function PMCLI:playlist_enqueue(item)
  if not self.playlist then
    self.playlist = { item }
  else
    self.playlist[#self.playlist + 1] = item
  end
end


function PMCLI:playlist_try_play_all()
  if self.playlist then
    self:play_media(self.playlist)
    self.playlist = nil
  end
end


function PMCLI:open_item(item, context)
	if item.search ~= "" then
		self:playlist_try_play_all()
		self:local_search(item, context)
	elseif item.name == "Directory" then
		self:playlist_try_play_all()
		self:open_menu(utils.join_keys(context, item.key))
	elseif item.name == "Track" then
		self:playlist_enqueue(item)
	elseif item.name == "Movie" or item.name == "Episode" then
		self:playlist_try_play_all()
		self:play_video(item)
	end
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
    choice = tonumber(utils.read())
    while not choice or choice < 1 or choice > #(metadata.Media) do
      io.stderr:write("[!!] Invalid choice.\n")
      choice = tonumber(utils.read())
    end
  end
  
  -- pretty bad to pollute the scope with this many variables but w/e
  local offset_to_part = 0
  local first_part = 1
  local last_part = #metadata.Media[choice].Part
  local force_resume = false
  if metadata.viewOffset and utils.confirm_yn(metadata.title .. " is set as partially viewed. Would you like to resume at " .. utils.msecs_to_time(metadata.viewOffset) .. "?") then
    force_resume = true
    -- NB we assume that if the viewOffset wasn't found up to the second-to-last part,
    -- then it surely is in the last part
    while first_part < last_part and offset_to_part + metadata.Media[choice].Part[first_part].duration < metadata.viewOffset do
      offset_to_part = offset_to_part + metadata.Media[choice].Part[first_part].duration
      first_part = first_part + 1
    end
    metadata.Media[choice].Part[first_part].view_offset = metadata.viewOffset - offset_to_part
  end
  
  -- notify user if there are many parts
  if last_part > first_part then
    io.stdout:write("\n-- Playback will consist of " .. last_part - first_part + 1 .. " files which will be played consecutively --\n\n")
  end
  
  -- all parts, each with their respective subtitles, are sent for playback
  for i = first_part, last_part do
    local stream_item = {
      title = item.title,
      duration = metadata.duration,
      rating_key = metadata.ratingKey,
      offset_to_part = offset_to_part,
      part_key = metadata.Media[choice].Part[i].key,
      view_offset = metadata.Media[choice].Part[i].view_offset,
      subs = { }
    }
    for _,s in ipairs(metadata.Media[choice].Part[i].Stream) do
      if s.streamType == 3 and s.key then
        -- it's an external subtitle
        stream_item.subs[#stream_item.subs + 1] = self.options.base_addr .. s.key
      end
    end
    
    -- as we have already prompted for resume, on the first file we will want
    -- to skip prompting again, if user said yes
    self:play_media({ stream_item }, force_resume and i == first_part)
    
    offset_to_part = offset_to_part + metadata.Media[choice].Part[i].duration
  end
end


function PMCLI:local_search(search_item, context)
  io.stdout:write("Query? > ");
  local query = "&query=" .. http_encode(io.read())
  search_item.key = search_item.key .. query
  self:open_menu(utils.join_keys(context, search_item.key))
end


function PMCLI:print_menu(context)
	local mc = self.sax.get_media_container()
	
	-- the API is inconsistent in how it publishes titles
	-- title2 is reasonably optional, as it marks nested contexts
	-- title1 is always there, except for global Recently Added and On Deck
	-- playlists just don't have either title1 or title2 :/
	-- for the sake of compute_title, we amend the payload to correct this
	if mc.title1 == "" then
		mc.title1 = "Global"
		if string.match(context, "recentlyAdded") then
			mc.title2 = "Recently Added"
		elseif string.match(context, "onDeck") then
			mc.title2 = "On Deck"
		elseif string.match(context, "playlists$") then
			mc.title2 = "Playlists"
		elseif string.match(context, "playlists/") then
			mc.title1 = mc.title
			mc.title2 = "Playlist"
			mc.mixed_parents = true
		end
	end
	
	io.stdout:write("\n=== " .. mc.title1 .. (mc.title2 ~= "" and  " - " .. mc.title2 or "") .. " ===\n")
	io.stdout:write("0: ..\n")
	local i = 1
	for item in self.sax.items() do
		local tag
		if item.search and item.search ~= "" then
			tag = "?"
		elseif item.type and item.type == "" then
			tag = "D"
		else
			tag = item.name:sub(1,1):upper()
		end
		io.stdout:write(tag .. " " .. i .. ": " .. pmcli.compute_title(item, mc) .. "\n")
		i = i + 1
	end
end


function PMCLI:open_menu(context)
	while true do
		assert(self:plex_request(context, true))
		assert(self.sax.parse(), "XML parsing error for request " .. self.options.base_addr .. context .. "\n")
		self:print_menu(context)
		for _,c in ipairs(utils.read_commands()) do
			if c == "q" then
				self:quit()
			elseif c == "*" then
				for item in self.sax.items() do
					self:open_item(item, context)
				end
			elseif c == 0 then
				return
			elseif c > 0 and c <= self.sax.child_count then
				require("pl.pretty").dump(self.sax.get(c))
				self:open_item(self.sax.get(c), context)
			end
		end
	end
	-- if the last item was audio we must still play it
	self:playlist_try_play_all()
--[[
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
    -- if the last item was audio we must still play it
    self:playlist_try_play_all()
  end
--]]
end
-- =============================


function PMCLI:run()
	io.stdout:write("Connecting to Plex Server...\n")
	local _, errmsg = pcall(function()
		local keys = {
			"/library/sections",
			"/library/recentlyAdded",
			"/library/onDeck",
			"/playlists"
		}
		while true do
			-- top menu has custom entries, so we manipulate it by hand (heh)
			io.stdout:write(PMCLI.ROOT_MENU)
			for _,c in ipairs(utils.read_commands()) do
				if c == "q" or c == 0 then
					self:quit()
				elseif c == "*" then
					for i = 1,4 do
						self:open_menu(keys[i])
					end
				elseif c > 0 and c < 5 then
					self:open_menu(keys[c])
				end
			end
		end
	end)
	self:quit(errmsg)
end


return pmcli
