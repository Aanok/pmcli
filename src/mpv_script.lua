-- ========== MODULE ==========
local pmcli = {
	VERSION = "0.2",
	AMBIGUOUS_CONTEXTS = {
		["On Deck"] = true,
		["Recently Added"] = true,
		["Recently Aired"] = true,
		["Recently Viewed Episodes"] = true
	}
}
-- ============================



-- ========== REQUIRES ==========
-- lua-http for networking
local http_request = require("http.request")

-- html entities (escape sequences)
local html_entities = require("htmlEntities")

-- JSON parsing
local json = require("dkjson").use_lpeg()

-- our own utils
local utils = require("pmcli.utils")

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
			if pmcli.AMBIGUOUS_CONTEXTS[html_entities.decode(parent_item.title2)] and item.grandparentTitle and item.index and item.parentIndex then
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
		return item.title
	elseif item.Media and item.Media[1].Part[1] then
		-- infer title from corresponding filename, like POSIX basename util
		return string.match(html_entities.decode(item.Media[1].Part[1].file), ".*/(.*)%..*")
	end
	-- either malformed item table or no media file to infer from
	return "Unknown title"
end
-- ===================================




-- ========== NETWORK ==========
-- headers for auth access
function pmcli.setup_headers(headers)
	headers:append("x-plex-client-identifier", pmcli.options.unique_identifier)
	headers:append("x-plex-product", "pmcli")
	headers:append("x-plex-version", pmcli.VERSION)
	headers:append("x-plex-token", pmcli.options.plex_token, true)
	headers:append("accept", "application/json")
end


function pmcli.plex_request(suffix, to_file)
	local request = http_request.new_from_uri(pmcli.options.base_addr ..  suffix)
	request.ctx = pmcli.ssl_context
	pmcli.setup_headers(request.headers)
	local headers, stream = request:go(10.0) -- 10 secs timeout
	if not headers then
		-- timeout or other network error of sorts
		return nil, "Network error on API request " .. pmcli.options.base_addr .. suffix .. ":\n" .. stream
	end
	if headers:get(":status") == "200" then
		return to_file and stream:save_body_to_file(pmcli.stream_file_handle) or stream:get_body_as_string()
	elseif headers:get(":status") == "401" then
		return nil, "API request " .. pmcli.options.base_addr .. suffix .. " returned error 401: unauthorized.\nYour token may have expired, consider logging in again by passing --login."
	else
		return nil, "API request " .. pmcli.options.base_addr .. suffix .. " returned error " .. headers:get(":status") .. "."
	end
end
-- =============================


-- ========== PLAYBACK ==========
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


function pmcli.mpv_socket_handle(playlist)
	local pos = 1
	local must_ask_offset = false
	local msg, err
	
	repeat
		msg, err = pmcli.mpv_socket:read()
		if msg == nil and err == 110 then
			-- timeout
			pmcli.mpv_socket:clearerr()
			pmcli.mpv_socket:write(PMCLI.IPC.GET_PLAYBACK_TIME)
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
				pmcli.mpv_socket:write(PMCLI.IPC.GET_PLAYBACK_TIME)
			elseif decoded.request_id == 1 and decoded.error == "success" then
				-- good reply to playback-time request
				item = pmcli:sync_progress(playlist[pos], math.floor(decoded.data*1000))
			end
		end
	until msg == nil and err ~= 110
	return pmcli.mpv_socket:eof(), err
end


function pmcli.play_media(playlist, force_resume)
	pmcli.navigating = false
	mp.set_property_bool("terminal", true)
	print("PLAYLIST: " .. require("mp.utils").to_string(playlist))
	pmcli.downloader:get(pmcli.options.base_addr .. playlist[1].part_key)
	local reply = pmcli.downloader:get_result()
	if reply == "ok" then
		require("cqueues").sleep(0.1)
		mp.commandv("loadfile", pmcli.stream_file_name)
	else
		return nil, reply
	end
--	pmcli.plex_request(playlist[1].part_key, true)
--[[
	local mpv_args = "--input-ipc-server=" .. pmcli.mpv_socket_name  
	mpv_args = mpv_args .. " --http-header-fields='x-plex-token: " .. pmcli.options.plex_token .. "'"
	mpv_args = mpv_args .. " --title='" .. playlist[1].title .. "'"
	
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
	pmcli:connect_mpv_socket()
	local joined = mpv_thread:join(0.5) -- if things go smooth this is enough
	while not pmcli.mpv_socket:peername() and not joined do
		joined = mpv_thread:join(5.0) -- if there's a problem, we give it a lot of time
	end
	
	if joined then
		io.stderr:write("[!] Couldn't reach IPC socket, playback progress was not synced to Plex server.\n")
	else
		-- request tracking for playlist's sake
		pmcli.mpv_socket:write('{ "command": ["observe_property", 1, "playlist-pos-1"] }\n')
		local ok, err = pmcli:mpv_socket_handle(playlist)
		if not ok then
			err = require("cqueues.errno").strerror(err)
			io.stderr:write("[!] IPC socket error: " .. err ..". Playback sync halted.\n" )
			-- TODO: improve this
		end
	end

	-- innocuous if already joined
	mpv_thread:join()
--]]
end


function pmcli.play_video(item)
	-- fetch metadata
	local body = assert(pmcli.plex_request(item.key))
	local reply = assert(json.decode(body))
	body = nil
	local metadata = assert(reply.MediaContainer and reply.MediaContainer.Metadata and reply.MediaContainer.Metadata[1],
		"Unexpected reply to API request " .. pmcli.options.base_addr .. item.key)
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
				stream_item.subs[#stream_item.subs + 1] = pmcli.options.base_addr .. s.key
			end
		end
		
		-- as we have already prompted for resume, on the first file we will want
		-- to skip prompting again, if user said yes
		pmcli.play_media({ stream_item }, force_resume and i == first_part)
		
		offset_to_part = offset_to_part + metadata.Media[choice].Part[i].duration
	end
end
-- ==============================


-- ========== NAVIGATION ==========
function pmcli.get_menu_items(reply, parent_key)
	local mc = reply.MediaContainer
	if not mc or not mc.title1 then
		return nil, "Unexpected reply to API request " .. pmcli.options.base_addr .. parent_key .. ":\n" .. utils.tostring(reply, true)
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
					offset_to_part = 0,
					rating_key = item.ratingKey,
					part_key = utils.join_keys(parent_key, item.Media[1].Part[1].key),
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


function pmcli.local_search(search_item)
	io.stdout:write("Query? > ");
	local query = "&query=" .. http_encode(io.read())
	search_item.key = search_item.key .. query
	-- consider the search a directory: register it
	pmcli.directory_stack:push(search_item)
	pmcli.open_menu(search_item)
end


-- used to dispatch commands about a specific menu item
-- bunches up consecutive audio requests into a single playlist command
-- enqueues the playlist when necessary (i.e. meeting a non-audio command)
function pmcli.dispatch_item_command(item)
	if pmcli.pending_audio then
		if item.tag == "T" then
			pmcli.pending_audio[#pmcli.pending_audio +1] = item
		else
			pmcli.command_queue:enqueue(pmcli.pending_audio)
			pmcli.pending_audio = nil
			pmcli.command_queue:enqueue(item)
		end
	else
		if item.tag == "T" then
			pmcli.pending_audio = { tag = "playlist", item }
		else
			pmcli.command_queue:enqueue(item)
		end
	end
end

-- enqueues pending audio playlist command, if any
function pmcli.try_dispatch_pending_audio()
	if pmcli.pending_audio then
		pmcli.command_queue:enqueue(pmcli.pending_audio)
		pmcli.pending_audio = nil
	end
end


function pmcli.open_menu(parent_item)
	local body = assert(pmcli.plex_request(parent_item.key))
	local reply = assert(json.decode(body), "Malformed JSON reply to request " .. pmcli.options.base_addr .. parent_item.key ..":\n" .. body)
	body = nil
	local items = assert(pmcli.get_menu_items(reply, parent_item.key))
	reply = nil
	utils.print_menu(items)
	local commands = utils.read_commands()
	for i = 1,#commands do
		if commands[i] == "q" then
			pmcli.quit()
		elseif commands[i] == "*" then
			for j = 1,#items do
				pmcli.dispatch_item_command(items[j])
			end
		elseif commands[i] == 0 then
			-- if the last item was audio we must still play it
			pmcli.try_dispatch_pending_audio()
			-- then leave
			pmcli.directory_stack:pop()
			return
		elseif commands[i] > 0 and commands[i] <= #items then
			pmcli.dispatch_item_command(items[commands[i]])
		end
	end
	-- if the last item was audio we must still play it
	pmcli.try_dispatch_pending_audio()
end


function pmcli.open_item(item)
	if item.tag == "D" or item.tag == "L" then
		-- register we've gone down a directory
		pmcli.directory_stack:push(item)
		pmcli.open_menu(item)
	elseif item.tag == "T" or item.tag == "playlist" then
		pmcli.play_media(item)
	elseif item.tag == "M" or item.tag == "E" then
		pmcli.play_video(item)
	elseif item.tag == "?" then
		pmcli.local_search(item)
	end
end


function pmcli.quit(error_message)
	mp.set_property_bool("terminal", false)
	io.close(pmcli.stream_file_handle)
	os.remove(pmcli.stream_file_name)
--	os.execute("stty " .. utils.stty_save) -- in case of fatal errors while mpv is running
	if error_message then
		io.stderr:write("[!!!] " .. error_message ..  "\n")
		os.exit(1)
	else
		os.exit(0)
	end
end


function pmcli.navigate()
	-- reset HTTP cache file to head
--	pmcli.downloader:get_result(0.1)
	pmcli.stream_file_handle:seek("set")
	-- set state to menu mode
	pmcli.navigating = true
	-- prevent key events from being forwarded to mpv and disables raw input mode
	mp.set_property_bool("terminal", false)
	while pmcli.navigating do
		-- evade pending commands if any, otherwise pop a directory
		local next_item = pmcli.command_queue:dequeue() or pmcli.directory_stack:pop()
--		io.stdout:write("STACK: " .. require("mp.utils").to_string(pmcli.directory_stack.m_stack) .. "\n")
--		io.stdout:write("QUEUE: " .. require("mp.utils").to_string(pmcli.command_queue.m_queue) .. "\n")
		local ok, errmsg = pcall(pmcli.open_item, next_item)
		if not ok then
			pmcli.quit(errmsg)
		end
	end
end
-- ================================


-- ========== INIT ==========
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
		plex_token, errmsg = pmcli.request_token(login, password, unique_identifier)
		if not plex_token then
			io.stderr:write("[!!] Authentication error:\n", errmsg .. "\n")
			if not utils.confirm_yn("Would you like to try again with new credentials?") then
				pmcli.quit("Configuration was unsuccessful.")
			end
		end
	until plex_token
	-- delete password from process memory as soon as possible
	password = nil
	collectgarbage()
	return plex_token, unique_identifier
end


function pmcli.first_time_config(skip_prompt, user_filename)
	if not skip_prompt and not utils.confirm_yn("\nConfiguration file not found. Would you like to proceed with configuration and login?") then
		pmcli.quit()
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
	
	options.plex_token, options.unique_identifier = pmcli.login()
	
	options.require_hostname_validation = not utils.confirm_yn("\nDo you need PMCLI to ignore hostname validation (must e.g. if using builtin SSL certificate)?")
	
	return options
end


function pmcli.request_token(login, pass, id)
	local request = http_request.new_from_uri("https://plex.tv/users/sign_in.json")
	request.headers:append("x-plex-client-identifier", id)
	request.headers:append("x-plex-product", "pmcli")
	request.headers:append("x-plex-version", pmcli.VERSION)
	request.headers:delete(":method")
	request.headers:append(":method", "POST")
	request.headers:append("content-type", "application/x-www-form-urlencoded")
	request.headers:append("accept", "application/json")
	request:set_body("user%5blogin%5d=" .. http_encode(login) .. "&user%5bpassword%5d=" .. http_encode(pass))
	local headers, stream = request:go()
	if not headers then
		pmcli.quit("Network error on token request: " .. stream)
	end
	local reply = json.decode(stream:get_body_as_string())
	if reply.error then
		return nil, reply.error
	else
		return reply.user.authentication_token
	end
end


do
	-- NB args have already been validated in Bash
	-- caveat insanity: options are TYPE-CHECKED by mpv!
	local args = {
		help = false,
		config = "",
		login = false
		}
	require("mp.options").read_options(args, "pmcli")
	io.stdout:write("Plex Media CLIent v" ..  pmcli.VERSION .. "\n")
	
	-- setup options from config file
	-- or, alternatively, ask user and login
	local must_save_config = false
	local error_message, error_code
	pmcli.options, error_message, error_code = utils.get_config(args.config)
	if not pmcli.options and error_code == 2 then
		-- config file not found
		-- if --login was passed, skip confirmation prompt
		pmcli.options = pmcli.first_time_config(args.login, args.config)
		must_save_config = true
	elseif not pmcli.options and error_code ~= 2 then
		-- real error
		pmcli.quit("Error opening configuration file:\n" .. error_message)
	end
	-- pmcli.options is valid from here onwards
	
	if not pmcli.options.pmcli_version or pmcli.options.pmcli_version ~= pmcli.VERSION then
		io.stdout:write("Check the changelog at https://github.com/Aanok/pmcli/blob/master/Changelog.md\n")
		pmcli.options.pmcli_version = pmcli.VERSION
		must_save_config = true
	end
	
	if args.login then
		-- config file found but user wants to redo login
		io.stdout:write("Attempting new login to obtain a new token.\n")
		pmcli.options.plex_token, pmcli.options.unique_identifier = pmcli.login()
		must_save_config = true
	end
	
	if must_save_config then
		io.stdout:write("Committing configuration to disk...\n")
		local ok, error_message, error_code = utils.write_config(pmcli.options, args.config)
		if not ok and error_code == -2 then
			io.stderr:write(error_message .. "\n")
		elseif not ok and error_code ~= -2 then
			pmcli.quit("Error writing configuration file:\n" .. error_message)
		end
	end
	
	-- if we need to step around mismatched hostnames from the certificate
	local http_tls = require("http.tls")
	http_tls.has_hostname_validation = pmcli.options.require_hostname_validation
	pmcli.ssl_context = http_tls.new_client_context()
	
	-- if we need to skip certificate validation
	if not pmcli.options.verify_server_certificates then
		pmcli.ssl_context:setVerify(require("openssl.ssl.context").VERIFY_NONE)
	end
	
	local quit_keys = utils.get_masked_input_conf_quit_binds()
	for key,command in pairs(quit_keys) do
		local ok, errmsg = pcall(mp.add_forced_key_binding, key, function() mp.command(command) end)
		if not ok then
			io.stderr:write("[!] Could not mask a quit keybind: " .. errmsg .. "\n")
		end
	end
	
	-- file for streaming media HTTP requests to
	pmcli.stream_file_name = os.tmpname()
	pmcli.stream_file_handle = io.open(pmcli.stream_file_name, "w")
	
	pmcli.downloader = utils.DOWNLOADER.new(pmcli.options, pmcli.stream_file_name)
	
	-- data structures for event loop navigation and user interface
	pmcli.directory_stack = utils.STACK.new()
	pmcli.command_queue = utils.QUEUE.new()
	
	-- register that we are in the root directory
	pmcli.directory_stack:push({ tag = "L", key = "/library/sections" })
	
	-- mpv event handlers
	mp.register_event("idle", pmcli.navigate)
	
	io.stdout:write("Connecting to Plex Server...\n")
end