--[[
after TAG NAME and TYPE (optional! only when needed to disambiguate),
fields are listed by tree pre-visit, then alphabetically
in short: NAME, TYPE, then alphabetically, then filename and part key

=== HEADER STRUCTURE ===
(NB offsets are saved as fixed-length binary reps by string.pack)
child1_count (should always be 0)
...
childn_offset
mc.mixedParents
mc.title (for playlists)
mc.title1
mc.title2


=== DIRECTORY ===
(for By Folder view these will only have Title and Key fields!)
(this will also cover Playlist items)
NAME
TYPE
index
key
mixedParents
parentTitle
search
title


=== TRACK ===
NAME
(no TYPE)
duration
grandparentTitle
mixedParents
parentTitle
ratingKey
title
viewOffset
FILE -- from ->Media->Part
PART_KEY -- from ->Media->Part


=== VIDEO - MOVIE === (menu entry)
NAME
TYPE
key
title
year
FILE -- from ->Media->Part


=== VIDEO - EPISODE === (menu entry)
NAME
TYPE
grandparentTitle
index
key
mixedParents
parentIndex
title
FILE -- from ->Media->Part
]]--

-- NB from testing, concatenation here is on average twice as fast as string.format

-- module
local sax = {}


-- ========== INTERNAL USE ==========
function sax.directory_start(parser, name, attributes)
	sax.header:write(string.pack(sax.uint_4b_fmt, sax.body:seek()))
	
	sax.body:write(name .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
	sax.body:write((attributes.index or "") .. "\n")
	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.mixedParents or "") .. "\n")
	sax.body:write((attributes.parentTitle or "") .. "\n")
	sax.body:write((attributes.search or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
end

function sax.part_start(parser, name, attributes)
	sax.body:write((attributes.file or "") .. "\n")
	if sax.looking_for_part == "Track" then
		sax.body:write((attributes.key or "") .. "\n")
	end
	sax.looking_for_part = nil
end


function sax.track_start(parser, name, attributes)
	sax.header:write(string.pack(sax.uint_4b_fmt, sax.body:seek()))

	sax.body:write(name .. "\n")
	sax.body:write((attributes.duration or "") .. "\n")
	sax.body:write((attributes.grandparentTitle or "") .. "\n")
	sax.body:write((attributes.mixedParents or "") .. "\n")
	sax.body:write((attributes.parentTitle or "") .. "\n")
	sax.body:write((attributes.ratingKey or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	sax.body:write((attributes.viewOffset or "") .. "\n")
	
	sax.looking_for_part = "Track" -- FILE, PART_KEY
end


function sax.movie_start(parser, name, attributes)
	sax.header:write(string.pack(sax.uint_4b_fmt, sax.body:seek()))

	sax.body:write(name .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	sax.body:write((attributes.year or "") .. "\n")
	
	sax.looking_for_part = "Video" -- FILE
end


function sax.episode_start(parser, name, attributes)
	sax.header:write(string.pack(sax.uint_4b_fmt, sax.body:seek()))

	sax.body:write(name .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
	sax.body:write((attributes.grandparentTitle or "") .. "\n")
	sax.body:write((attributes.index or "") .. "\n")
	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.mixedParents or "") .. "\n")
	sax.body:write((attributes.parentIndex or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	
	sax.looking_for_part = "Video" -- FILE
end


function sax.media_container_start(parser, name, attributes)
	-- save attributes, we will write them at the end of the header
	sax.header_attrs = attributes
end


function sax.media_container_end(parser, name)
	sax.header:write((sax.header_attrs.mixedParents or "") .. "\n")
	sax.header:write((sax.header_attrs.title or "") .. "\n")
	sax.header:write((sax.header_attrs.title1 or "") .. "\n")
	sax.header:write((sax.header_attrs.title2 or "") .. "\n")
	sax.header_attrs = nil
	sax.header:flush() -- seek USUALLY also flushes, but it's not in the spec
	sax.body:flush()
	sax.header:seek("set")
	sax.body:seek("set")
end


function sax.element_start(parser, name, attributes)
	if name == "MediaContainer" then
		sax.media_container_start(parser, name, attributes)
	elseif name == "Directory" then
		sax.child_count = sax.child_count + 1
		sax.directory_start(parser, name, attributes)
	elseif name == "Track" then
		sax.child_count = sax.child_count + 1
		sax.track_start(parser, name, attributes)
	elseif name == "Video" and attributes.type == "movie" then
		sax.child_count = sax.child_count + 1
		sax.movie_start(parser, name, attributes)
	elseif name == "Video" and attributes.type == "episode" then
		sax.child_count = sax.child_count + 1
		sax.episode_start(parser, name, attributes)
	elseif name == "Playlist" then
		sax.child_count = sax.child_count + 1
		sax.directory_start(parser, name, attributes)
	elseif name == "Part" and sax.looking_for_part then
		sax.part_start(parser, name, attributes)
	end
end


function sax.element_end(parser, name)
	if name == "MediaContainer" then
		sax.media_container_end(parser, name)
	end
end
-- ==================================


-- ========== EXTERNAL USE ===========
function sax.init(header_filename, body_filename, stream_filename)
	sax.header_filename = header_filename
	sax.body_filename = body_filename
	sax.stream_filename = stream_filename
	sax.uint_4b_fmt = "=I4" -- native endianness, unsigned 4B integer
	sax.uint_4b_sizeof = string.packsize(sax.uint_4b_fmt) -- always 4 but w/e
	sax.lxp = require("lxp")
end


function sax.destroy()
	if sax.header then
		sax.header:close()
		os.remove(sax.header_filename)
	end
	if sax.body then
		sax.body:close()
		os.remove(sax.body_filename)
	end
end


function sax.parse()
	if not sax.uint_4b_sizeof then return nil, "parser not initialized" end
	-- open/reset local buffer files
	sax.header = assert(io.open(sax.header_filename, "w+"))
	sax.body = assert(io.open(sax.body_filename, "w+"))
	sax.child_count = 0
	sax.parser = sax.lxp.new({
		StartElement = sax.element_start,
		EndElement = sax.element_end
	})
	for line in io.lines(sax.stream_filename) do
		local ok, msg, line, col, pos = sax.parser:parse(line)
		if not ok then return nil, msg, line, col, pos end
	end
	sax.parser:close()
	return true
end


function sax.get_media_container()
	local mc = {}
	sax.header:seek("set", sax.child_count * sax.uint_4b_sizeof)
	mc.mixed_parents = sax.header:read()
	mc.title = sax.header:read()
	mc.title1 = sax.header:read()
	mc.title2 = sax.header:read()
	-- second pass: null empty strings
	for k,v in pairs(mc) do
		if v == "" then mc[k] = nil end
	end
	return mc
end


-- parses the item at the current seek position in body
-- returning a Lua table
function sax.get_current()
	el = { name = sax.body:read() }
	if el.name == "Directory" or el.name == "Playlist" then
		el.type = sax.body:read()
		el.index = tonumber(sax.body:read())
		el.key = sax.body:read()
		el.mixed_parents = sax.body:read()
		el.parent_title = sax.body:read()
		el.search = sax.body:read()
		el.title = sax.body:read()
	elseif el.name == "Track" then
		el.duration = tonumber(sax.body:read())
		el.grandparent_title = sax.body:read()
		el.mixed_parents = sax.body:read()
		el.parent_title = sax.body:read()
		el.rating_key = sax.body:read()
		el.title = sax.body:read()
		el.view_offset = tonumber(sax.body:read())
		el.file = sax.body:read()
		el.part_key = sax.body:read()
	elseif el.name == "Video" then
		el.type = sax.body:read()
		if el.type == "movie" then
			el.key = sax.body:read()
			el.title = sax.body:read()
			el.year = sax.body:read()
			el.file = sax.body:read()
		elseif el.type == "episode" then
			el.grandparent_title = sax.body:read()
			el.index = sax.body:read()
			el.key = sax.body:read()
			el.mixed_parents = sax.body:read()
			el.parent_index = sax.body:read()
			el.title = sax.body:read()
			el.file = sax.body:read()
		end
	end
	-- second pass: reduce empty strings to nil
	-- this sounds slow, but it's only critical during printing,
	-- where the bottleneck is vastly due to the terminal
	for k,v in pairs(el) do
		if v == "" then el[k] = nil end
	end
	return el
end

-- returns a table with the i-th child of the container (1-indexed)
function sax.get(i)
	if i < 1 or i > sax.child_count then
		-- out of bounds; could be parser wasn't run
		return nil, "no such item available"
	elseif i == 1 then
		-- don't want to read the first number in the header, which is child_count
		-- first child starts at 0 offset
		sax.body:seek("set")
	else
		sax.header:seek("set", (i-1)*sax.uint_4b_sizeof)
		sax.body:seek("set", string.unpack("=I4", sax.header:read(sax.uint_4b_sizeof)))
	end
	return sax.get_current()
end


-- iterator, returns all items
function sax.items()
	sax.body:seek("set")
	local i = 0
	return function()
		if i < sax.child_count then
			i = i + 1
			return sax.get_current()
		end
	end
end


return sax