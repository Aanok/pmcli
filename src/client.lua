-- module
-- we init some "static" values
local pmcli = {
  VERSION = "0.2.1",
  HELP_TEXT = [[Usage:
  pmcli [ --login ] [ --config configuration_file ]
  pmcli [ --help ] ]],
  IPC = {
    GET_PLAYBACK_TIME = '{ "command": ["get_property", "playback-time"], "request_id": 1 }\n'
  },
  ROOT_MENU = [[

=== Plex Server ===
0. quit
D 1. Library Sections
D 2. Recently Added Content
D 3. On Deck Content
D 4. Playlists
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
local json = require("pmcli.dkjson")

-- to drive mpv in parallel
local thread = require("cqueues.thread")

-- HTTP URL escaping
local http_encode = require("http.util").encodeURIComponent
-- ==============================


-- ========== NETWORK ==========
function pmcli.plex_request(suffix, to_file, base_addr)
	local base_addr = base_addr or pmcli.options.base_addr
	local request = http_request.new_from_uri(base_addr ..  suffix)
	request.ctx = pmcli.ssl_context
	request.headers:append("x-plex-client-identifier", pmcli.options.unique_identifier)
	request.headers:append("x-plex-product", "pmcli")
	request.headers:append("x-plex-version", pmcli.VERSION)
	if pmcli.options.plex_token then
		request.headers:append("x-plex-token", pmcli.options.plex_token, true)
	end
	local headers, stream = request:go(pmcli.options.request_timeout) -- 10 secs timeout
	if not headers then
		-- timeout or other network error of sorts
		return nil, "Network error on API request " .. base_addr .. suffix .. ":\n" .. stream
	end
	if headers:get(":status") == "200" then
		if to_file then
			pmcli.stream_file_handle = assert(io.open(pmcli.stream_filename, "w"))
			stream:save_body_to_file(pmcli.stream_file_handle)
			assert(pmcli.stream_file_handle:close())
			return true
		else
			return stream:get_body_as_string()
		end
	elseif headers:get(":status") == "401" then
		return nil,
		"API request " .. base_addr .. suffix .. " returned error 401: unauthorized.\nYour token was rejected, consider logging in again by passing --login.",
		headers:get(":status")
	else
		return nil,
		"API request " .. base_addr .. suffix .. " returned error " .. headers:get(":status") .. ".",
		headers:get(":status")
	end
end


function pmcli.sync_progress(item, msecs)
	if item.duration and item.rating_key then
		-- rating_key should always be there tbh, but duration might actually be missing if
		-- a metadata update is in progress or such
		if not item.last_sync or math.abs(item.last_sync - msecs) > 10000 then
			-- there is actual progress to update
			local total_msecs = item.offset_to_part + msecs
			if total_msecs > item.duration * 0.95 then -- close enough to end, scrobble
				local ok, error_msg = pmcli.plex_request("/:/scrobble?key=" .. item.rating_key .. "&identifier=com.plexapp.plugins.library")
				if not ok then
					io.stderr:write("[!] " .. error_msg .. "\n")
				else
					item.last_sync = nil
				end
			elseif total_msecs > item.duration * 0.05 then -- far enough from start, update viewOffset
				local ok, error_msg = pmcli.plex_request("/:/progress?key=" .. item.rating_key .. "&time=" .. total_msecs .. "&identifier=com.plexapp.plugins.library")
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
-- =============================


-- ========== PLAYBACK ==========
function pmcli.mpv_socket_handle(playlist)
	local pos = 1
	local must_ask_offset = false
	local msg, err

	repeat
		msg, err = pmcli.mpv_socket:read()
		if msg == nil and err == 110 then
			-- timeout
			pmcli.mpv_socket:clearerr()
			pmcli.mpv_socket:write(pmcli.IPC.GET_PLAYBACK_TIME)
		elseif msg then
			local decoded = json.decode(msg)
			if decoded.event == "property-change" and decoded.id == 1 then
				-- playlist-pos-1
				pos = decoded.data
				if pos ~= 1 and playlist[pos].view_offset then
					-- there is a bookmark, so we must prompt the user about it
					-- but note: the first item's already been taken care of
					-- mpv's term-playing-msg, tracks and tags will be shown before the prompt
					pmcli.mpv_socket:write('{ "command": ["set_property", "pause", true] }\n')
					must_ask_offset = true
				end
			elseif must_ask_offset and decoded.event == "pause" then
				-- mpv has written its header and is about to print term-status-msg
				-- which we don't want because it will interleave and overlap with our I/O
				-- so we disable mpv's terminal functionalities altogether (in,err,out)
				pmcli.mpv_socket:write('{ "command": ["set_property", "terminal", false] }\n')
				local offset_time = utils.msecs_to_time(playlist[pos].view_offset)
				-- mpv disables tty echo and maybe other functionalities
				local mpv_stty = utils.save_stty()
				os.execute("stty " .. utils.stty_save)
				if utils.confirm_yn("\n" .. playlist[pos].title .. " is set as partially viewed. Would you like to resume at " .. offset_time .. "?") then
					pmcli.mpv_socket:write(string.format('{ "command": ["seek", "%s"] }\n', offset_time))
				end
				io.stdout:write("\n")
				os.execute("stty " .. mpv_stty)
				must_ask_offset = false
				pmcli.mpv_socket:write('{ "command": ["set_property", "terminal", true] }\n')
				pmcli.mpv_socket:write('{ "command": ["set_property", "pause", false] }\n')
			elseif decoded.event == "seek" then
				pmcli.mpv_socket:write(pmcli.IPC.GET_PLAYBACK_TIME)
			elseif decoded.request_id == 1 and decoded.error == "success" then
				-- good reply to playback-time request
				item = pmcli.sync_progress(playlist[pos], math.floor(decoded.data*1000))
			end
		end
	until msg == nil and err ~= 110
	return pmcli.mpv_socket:eof(), err
end


function pmcli.play_media(playlist, force_resume)
	local mpv_args = "--input-ipc-server=" .. pmcli.mpv_socket_name
	if pmcli.options.plex_token then
		mpv_args = mpv_args .. " --http-header-fields='x-plex-token: " .. pmcli.options.plex_token .. "'"
	end
	if pmcli.options.mpv_profile then
		mpv_args = mpv_args .. " --profile='" .. pmcli.options.mpv_profile .."'"
	end
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
		mpv_args = mpv_args .. " " .. pmcli.options.base_addr .. item.part_key
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
	pmcli.mpv_socket = socket.connect({ path = pmcli.mpv_socket_name })
	local joined = mpv_thread:join(0.5) -- if things go smooth this is enough
	while not pmcli.mpv_socket:peername() and not joined do
		joined = mpv_thread:join(5.0) -- if there's a problem, we give it a lot of time
	end

	if joined then
		io.stderr:write("[!] Couldn't reach IPC socket, playback progress was not synced to Plex server.\n")
	else
		-- request tracking for playlist's sake
		pmcli.mpv_socket:write('{ "command": ["observe_property", 1, "playlist-pos-1"] }\n')
		local ok, err = pmcli.mpv_socket_handle(playlist)
		if not ok then
			io.stderr:write("[!] IPC socket error: " .. require("cqueues.errno").strerror(err) ..". Playback sync halted.\n" )
			-- TODO: improve this
		end
	end

	-- innocuous if already joined
	mpv_thread:join()
end


function pmcli.play_video(item)
	-- fetch metadata, small payload for sure so we work in-memory
	local reply = assert(lxp_lom.parse(assert(pmcli.plex_request(item.key))))
	assert(reply.tag == "MediaContainer" and #reply > 1, "Unexpected reply to API request " .. pmcli.options.base_addr .. item.key)
	
	-- sanitize; NB preserves nil
	reply[2].attr.viewOffset = tonumber(reply[2].attr.viewOffset)
	
	---- VERSIONS ----
	local media = {}
	for _,v in ipairs(reply[2]) do
		if v.tag == "Media" then
			media[#media +1] = v
		end
	end

	local choice = 1
	if #(media) > 1 then
		-- there are multiple versions and the user must choose
		io.stdout:write("\nThere are multiple versions for " .. item.title .. ":\n")
		for i,m in ipairs(media) do
			local width = m.attr.width or "unknown width "
			local height = m.attr.height or "unkown height "
			local video_codec = m.attr.videoCodec or "unknown codec"
			local audio_channels = m.attr.audioChannels or "unknown"
			local audio_codec = m.attr.audioCodec or "unknown codec"
			local bitrate = m.attr.bitrate and m.attr.bitrate .. "kbps" or "unknown bitrate"
			io.stdout:write(i .. ": " .. width .. "x" .. height .. " " .. video_codec .. ", " ..  audio_channels .. " channel " .. audio_codec .. ", " .. bitrate .. "\n")
		end
		-- user choice
		io.stdout:write("Please select one for playback: ")
		choice = tonumber(utils.read())
		while not choice or choice < 1 or choice > #(media) do
			io.stderr:write("[!!] Invalid choice.\n")
			choice = tonumber(utils.read())
		end
	end

	---- PARTS ----
	local parts = {}
	for _,v in ipairs(media[choice]) do
		if v.tag == "Part" then
			parts[#parts +1] = v
			-- sanitize
			v.attr.duration = tonumber(v.attr.duration)
		end
	end
	-- reverse parts, so offset computation can drop from tail instead of head
	for i = 1, #parts/2 do
		local tmp = parts[i]
		parts[i] = parts[#parts - i + 1]
		parts[#parts - i + 1] = tmp
	end

	parts.offset = 0
	local force_resume = false
	if reply[2].attr.viewOffset and utils.confirm_yn(item.title .. " is set as partially viewed. Would you like to resume at " .. utils.msecs_to_time(reply[2].attr.viewOffset) .. "?") then
		force_resume = true
		-- NB we assume that if the viewOffset wasn't found up to the second-to-last part,
		-- then it surely is in the last part
		while #parts > 1 and parts.offset + parts[#parts].attr.duration < reply[2].attr.viewOffset do
			parts.offset = parts.offset + parts[#parts].attr.duration
			parts[#parts] = nil
		end
		parts[1].attr.viewOffset = reply[2].attr.viewOffset - parts.offset
	end

	-- notify user if there are many parts
	if #parts > 1 then
		io.stdout:write("\n-- Playback will consist of " .. #parts .. " files which will be played consecutively --\n\n")
	end

	---- PLAYBACK ----
	for i = #parts, 1, -1 do
		local stream_item = {
			title = item.title,
			duration = reply[2].attr.duration,
			rating_key = reply[2].attr.ratingKey,
			offset_to_part = parts.offset,
			part_key = parts[i].attr.key,
			view_offset = parts[i].attr.viewOffset,
			subs = { }
		}
		for _,v in ipairs(parts[i]) do
			if v.tag == "Stream" and v.attr.streamType == "3" and v.attr.key then
				-- it's an external subtitle
				stream_item.subs[#stream_item.subs + 1] = pmcli.options.base_addr .. v.attr.key
			end
		end

		-- as we have already prompted for resume, on the first file we will want
		-- to skip prompting again, if user said yes
		pmcli.play_media({ stream_item }, force_resume and i == #parts)

		parts.offset = parts.offset + parts[i].attr.duration
	end
end


function pmcli.playlist_enqueue(item)
	item.offset_to_part = 0 -- bad hack, TODO: review
	if not pmcli.playlist then
		pmcli.playlist = { item }
	else
		pmcli.playlist[#pmcli.playlist + 1] = item
	end
end


function pmcli.playlist_try_play_all()
	if pmcli.playlist then
		pmcli.play_media(pmcli.playlist)
		pmcli.playlist = nil
	end
end
-- ==============================


-- ========== INTERFACE ==========
function pmcli.open_item(item, context)
	if item.search == "1" then
		pmcli.playlist_try_play_all()
		pmcli.local_search(item, context)
	elseif item.name == "Directory" or item.name == "Playlist" then
		pmcli.playlist_try_play_all()
		pmcli.open_menu(utils.join_keys(context, item.key))
	elseif item.name == "Track" then
		pmcli.playlist_enqueue(item)
	elseif item.name == "Video" then
		pmcli.playlist_try_play_all()
		pmcli.play_video(item)
	end
end


function pmcli.local_search(search_item, context)
	io.stdout:write("Query? > ");
	local query = "&query=" .. http_encode(io.read())
	search_item.key = search_item.key .. query
	pmcli.open_menu(utils.join_keys(context, search_item.key))
end


function pmcli.print_menu(context)
	local mc = pmcli.sax.get_media_container()
	
	-- the API is inconsistent in how it publishes titles
	-- title2 is reasonably optional, as it marks nested contexts
	-- title1 is always there, except for global Recently Added and On Deck
	-- playlists have a "title" :/
	-- we amend the payload to correct this
	if mc.title1 == nil then
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
	
	io.stdout:setvbuf("full")
	io.stdout:write("\n=== " .. mc.title1 .. (mc.title2 and  " - " .. mc.title2 or "") .. " ===\n")
	io.stdout:write("0: ..\n")
	local i = 1
	for item in pmcli.sax.items() do
		local tag
		if item.search == "1" then
			tag = "?"
		elseif item.name == "Directory" or item.name == "Playlist" then
			tag = "D"
		else
			tag = item.name:sub(1,1)
		end
		local title
		if item.title then
			-- title field is filled, use it
			-- this should mean there is, generally speaking, available metadata
			if item.type == "episode" then
				-- for tv shows we want to show information on show title, season and episode number
				if mc.mixed_parents and item.grandparent_title and item.index and item.parent_index then
					-- menus where there is a jumble of shows and episodes, so we must show everything
					title = string.format("%s - S%02dE%02d - %s",
					item.grandparent_title,
					item.parent_index,
					item.index,
					item.title)
				elseif mc.mixed_parents and item.index and item.parent_index then
					-- mixedParents marks a generic promiscuous context, but we ruled out cases where shows are mixed
					-- so we only need season and episode
					title = string.format("S%02dE%02d - %s", item.parent_index, item.index, item.title)
				elseif item.index then
					-- here we should be in a specific season, so we only need the episode
					title = string.format("E%02d - %s", item.index, item.title)
				end
			elseif item.type == "movie" and item.year then
				-- add year
				title = item.title .. " (" .. item.year .. ")"
			elseif (item.type == "album" or item.type == "season") and mc.mixed_parents and item.parent_title then
				-- artist - album / show - season
				title = item.parent_title .. " - " .. item.title
			elseif item.name == "Track" and mc.mixed_parents and item.grandparent_title and item.parent_title then
				-- prefix with artist name and album
				title = item.grandparent_title .. " - " .. item.parent_title .. " - " .. item.title
			else
				-- no need for or availability of further information
				title = item.title
			end
		elseif item.file then
			-- infer title from corresponding filename, like POSIX basename util
			title = string.match(item.file, ".*/(.*)%..*")
		else
			title = "Unknown title"
		end
		io.stdout:write(tag .. " " .. i .. ": " .. title .. "\n")
		i = i + 1
	end
	io.stdout:flush()
	io.stdout:setvbuf("line")
end


function pmcli.open_menu(context)
	while true do
		assert(pmcli.plex_request(context, true))
		assert(pmcli.sax.parse(), "XML parsing error for request " .. pmcli.options.base_addr .. context)
		pmcli.print_menu(context)
		for _,c in ipairs(utils.read_commands()) do
			if c == "q" then
				pmcli.quit()
			elseif c == "*" then
				for item in pmcli.sax.items() do
					pmcli.open_item(item, context)
				end
			elseif c == 0 then
				return
			elseif c > 0 and c <= pmcli.sax.child_count then
				pmcli.open_item(pmcli.sax.get(c), context)
			end
		end
		-- if the last item was audio we must still play it
		pmcli.playlist_try_play_all()
	end
end


function pmcli.quit(error_message)
	if pmcli.mpv_socket_name then os.remove(pmcli.mpv_socket_name) end
	if pmcli.sax then pmcli.sax.destroy() end
	if pmcli.stream_filename then os.remove(pmcli.stream_filename) end
	if pmcli.session_filename then os.remove(pmcli.session_filename) end
	os.execute("stty " .. utils.stty_save) -- in case of fatal errors while mpv is running
	if error_message then
		io.stderr:write("[!!!] " .. error_message ..  "\n")
		os.exit(1)
	else
		os.exit(0)
	end
end


function pmcli.start(arg)
	pmcli.init(arg)
	
	if pmcli.options.plex_token then
		-- check token validity; calling mothership ensures we bypass server-side IP whitelists
		local ok, errmsg, errno = pmcli.plex_request("", false, "https://plex.tv/pms")
		if not ok then
			if errno == "401" then
				io.stdout:write("[!] Your token was rejected. If your IP address is whitelisted on your server, PMCLI should keep working.\nOtherwise, consider logging in again by passing --login.\n")
				-- this will remove x-plex-token from API and mpv requests
				pmcli.options.plex_token = nil
			else
				io.stdout:write("[!] Could not validate token: " .. (errno and ("https://plex.tv/pms returned error " .. errno) or errmsg) .. ".\n")
			end
		end
	end
	
	_, errmsg = pcall(function()
		local keys = {
			"/library/sections",
			"/library/recentlyAdded",
			"/library/onDeck",
			"/playlists"
		}
		while true do
			-- ensure connectivity to server
			assert(pmcli.plex_request(""))
			-- top menu has custom entries, so we manipulate it by hand (heh)
			io.stdout:write(pmcli.ROOT_MENU)
			for _,c in ipairs(utils.read_commands()) do
				if c == "q" or c == 0 then
					pmcli.quit()
				elseif c == "*" then
					for i = 1,4 do
						pmcli.open_menu(keys[i])
					end
				elseif c > 0 and c < 5 then
					pmcli.open_menu(keys[c])
				end
			end
		end
	end)
	pmcli.quit(errmsg)
end
-- ===============================


-- ========== SETUP ==========
function pmcli.login()
	local plex_token
	local unique_identifier = "pmcli-" .. utils.generate_random_id()
	repeat 
		io.stdout:write("\nPlease enter your Plex account name or email.\n")
		local login = utils.read()
		io.stdout:write("\nPlease enter your Plex account password.\n")
		local password, errmsg = utils.read_password()
		if not password then
			pmcli.quit(errmsg)
		end
	
		local request = http_request.new_from_uri("https://plex.tv/users/sign_in.xml")
		request.headers:upsert(":method", "POST")
		request.headers:append("content-type", "application/x-www-form-urlencoded")
		request.headers:append("x-plex-client-identifier", unique_identifier)
		request.headers:append("x-plex-product", "pmcli")
		request.headers:append("x-plex-version", pmcli.VERSION)
		request:set_body("user%5blogin%5d=" .. http_encode(login) .. "&user%5bpassword%5d=" .. http_encode(password))
		local headers, stream = request:go()
		if not headers then
			pmcli.quit("Network error on token request: " .. stream)
		end
		local reply = lxp_lom.parse(stream:get_body_as_string())
		if reply[2].tag == "error" then
			plex_token, errmsg = nil, reply[2][1]
		else
			io.stdout:write("\nLogin successful.\n")
			plex_token = reply.attr.authenticationToken
		end

		if not plex_token then
			io.stderr:write("[!!] Authentication error: ", errmsg .. "\n")
			if not utils.confirm_yn("Would you like to try again with new credentials?") then
				pmcli.quit("Error during account login.")
			end
		end
	until plex_token
	-- delete password from process memory as soon as possible
	collectgarbage()
	
	return plex_token, unique_identifier
end


function pmcli.first_time_config(skip_prompt, user_filename)
	if not skip_prompt and not utils.confirm_yn("\nConfiguration file not found. Would you like to proceed with configuration and login?") then
		pmcli.quit()
	end

	local options = {}

	---- LOGIN ----
	options.plex_token, options.unique_identifier = pmcli.login()

	---- SERVER SELECTION ----
	local reply
	while not reply do
		local request = http_request.new_from_uri("https://plex.tv/pms/resources.xml")
		request.ctx = pmcli.ssl_context
		request.headers:append("x-plex-client-identifier", options.unique_identifier)
		request.headers:append("x-plex-product", "pmcli")
		request.headers:append("x-plex-version", pmcli.VERSION)
		request.headers:append("x-plex-token", options.plex_token, true)
		local headers, stream = request:go(10.0) -- 10 secs timeout
		if not headers then
			-- timeout or other network error of sorts
			io.stdout:write("[!!] Network error on API request https://plex.tv/pms/resources.xml:\n" .. stream .. "\n")
		end
		if headers:get(":status") == "200" then
			reply = lxp_lom.parse(stream:get_body_as_string())
		else
			io.stdout:write("[!!] API request https://plex.tv/pms/resources.xml returned error " .. headers:get(":status") .. ".\n")
		end
		if not reply and not utils.confirm_yn("\nWould you like to try connecting again?") then
			pmcli.quit("Error during server discovery.")
		end
	end
	
	local servers = {}
	for _,d in pairs(reply) do
		if d.tag == "Device" and d.attr.provides == "server" then
			for _,c in pairs(d) do
				if c.tag == "Connection" then
					servers[#servers + 1] = {
						name = d.attr.name,
						addr = c.attr.uri
					}
				end
			end
		end
	end
	
	io.stdout:write("\nWhich address should PMCLI connect to?\n")
	for i = 1, #servers do
		io.stdout:write(i .. ": " .. servers[i].name .. " @ " .. servers[i].addr .. "\n")
	end
	io.stdout:write(#servers + 1 .. ": input address by hand\n")
	local selection = tonumber(utils.read())
	while not selection or selection < 1 or selection > #servers + 1 do
		io.stdout:write("[!!] Invalid choice. Please try again.\n")
		selection = tonumber(utils.read())
	end
	
	if selection == #servers + 1 then  
		local uri_patt = require("lpeg_patterns.uri").uri * -1
		io.stdout:write("\nPlease enter an address (and port if not default) to access your Plex Media Server.\nIt should look like https://example.com:32400 .\n")
		repeat
			options.base_addr = utils.read()
			if not uri_patt:match(options.base_addr) then
				io.stderr:write("[!!] Malformed URI. Please try again.\n")
			end
		until uri_patt:match(options.base_addr)
	else
		options.base_addr = servers[selection].addr
	end
	
	---- MISC OPTIONS ----
	options.require_hostname_validation = not utils.confirm_yn("\nDo you need PMCLI to ignore hostname validation (must e.g. if using builtin SSL certificate)?")
  
  return options
end


-- inizialize
function pmcli.init(arg)
	io.stdout:write("Plex Media CLIent v" ..  pmcli.VERSION .. "\n")

	---- CLI ARGUMENTS ----
	local parsed_args = {}
	local i = 1
	while i <= #arg do
		if arg[i] == "--login" then
			parsed_args.login = true
		elseif arg[i] == "--help" then
			io.stdout:write(pmcli.HELP_TEXT .. "\n")
			pmcli.quit()
		elseif arg[i] == "--config" then
			-- next argument should be parameter
			if not arg[i + 1] then
				pmcli.quit("--config requires a filename.")
			end
			parsed_args.config_filename = arg[i + 1]
			i = i + 1
		else
			pmcli.quit("Unrecognized command line option: " .. arg[i] .. "\n" .. pmcli.HELP_TEXT)
		end
		i = i + 1
	end

	---- CONFIG FILE ----
	-- read file or ask user and login
	local must_save_config = false
	local error_message, error_code
	pmcli.options, error_message, error_code = utils.get_config(parsed_args.config_filename)
	if not pmcli.options and error_code == 2 then
		-- config file not found
		-- if --login was passed, skip confirmation prompt
		pmcli.options = pmcli.first_time_config(parsed_args.login, parsed_args.config_filename)
		parsed_args.login = nil
		must_save_config = true
		io.stdout:write("\n")
	elseif not pmcli.options and error_code ~= 2 then
		-- real error
		pmcli.quit("Error opening configuration file:\n" .. error_message)
	end
	-- pmcli.options is valid from here onwards

	if error_code == nil and (not pmcli.options.pmcli_version or pmcli.options.pmcli_version ~= pmcli.VERSION) then
		-- update, possibly from old version still not tracking version number
		io.stdout:write("Check the changelog at https://github.com/Aanok/pmcli/blob/master/Changelog.md\n")
		pmcli.options.pmcli_version = pmcli.VERSION
		must_save_config = true
	end

	if parsed_args.login then
		-- config file found but user wants to redo login
		io.stdout:write("Attempting new login to obtain a new token.\n\n")
		pmcli.options.plex_token, pmcli.options.unique_identifier = pmcli.login()
		must_save_config = true
	end

	if must_save_config then
		io.stdout:write("Committing configuration to disk...\n")
		local ok, error_message, error_code = utils.write_config(pmcli.options, parsed_args.config_filename)
		if not ok and error_code == -2 then
			io.stderr:write(error_message .. "\n")
		elseif not ok and error_code ~= -2 then
			pmcli.quit("Error writing configuration file:\n" .. error_message)
		end
	end

	---- MISC OPTIONS ----
	-- if we need to step around mismatched hostnames from the certificate
	local http_tls = require("http.tls")
	http_tls.has_hostname_validation = pmcli.options.require_hostname_validation
	pmcli.ssl_context = http_tls.new_client_context()

	-- if we need to skip certificate validation
	if not pmcli.options.verify_server_certificates then
		pmcli.ssl_context:setVerify(require("openssl.ssl.context").VERIFY_NONE)
	end
	
	-- sanitize
	pmcli.options.request_timeout = tonumber(pmcli.options.request_timeout)


	---- TEMP FILES ----
	assert(os.execute("mkdir -p -m 700 /tmp/pmcli"))
	pmcli.session_filename = "/tmp/pmcli/" .. utils.generate_random_id(10)
	-- overkill: ensure session id isn't already taken for some reason
	_,_,error_code = os.rename(pmcli.session_filename, pmcli.session_filename)
	while error_code ~= 2 do -- until "no such file"
		pmcli.session_filename = "/tmp/pmcli/" .. utils.generate_random_id(10)
		_,_,error_code = os.rename(pmcli.session_filename, pmcli.session_filename)
	end
	assert(assert(io.open(pmcli.session_filename, "w"):close()))

	pmcli.stream_filename = pmcli.session_filename .. "_stream"

	pmcli.mpv_socket_name = pmcli.session_filename .. "_socket"
	socket.settimeout(10.0) -- new default

	pmcli.sax = require("pmcli.sax")
	pmcli.sax.init(pmcli.session_filename .. "_header", pmcli.session_filename .. "_body", pmcli.stream_filename)
end
-- ===========================

return pmcli
