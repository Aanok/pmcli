--[[
fields are listed by tree pre-visit, then alphabetically
in short: alphabetically, then filename and part key

=== HEADER STRUCTURE ===
mc.mixedParents
mc.title1
mc.title2
child1_offset (it should be 0)
...
childn_offset


=== DIRECTORY ===
index
key
mixedParents
parentTitle
search
title
type


=== TRACK ===
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
key
title
type
year
FILE -- from ->Media->Part


=== VIDEO - EPISODE === (menu entry)
grandparentTitle
index
key
mixedParents
parentIndex
title
type
FILE -- from ->Media->Part
]]--

-- NB from testing, concatenation here is on average twice as fast as string.format

-- module
local sax = {}


-- ========== INTERNAL USE ==========
function sax.directory_start(parser, name, attributes)
	sax.header:write(sax.body:seek() .. "\n")
	
	sax.body:write((attributes.index or "") .. "\n")
	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.mixedParents or "") .. "\n")
	sax.body:write((attributes.parentTitle or "") .. "\n")
	sax.body:write((attributes.search or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
end

function sax.part_start(parser, name, attributes)
	sax.body:write((attributes.file or "") .. "\n")
	if cbx.looking_for_part == "Track" then
		sax.body:write((attributes.key or "") .. "\n")
	end
	sax.looking_for_part = nil
end


function sax.track_start(parser, name, attributes)
	sax.header:write(sax.body:seek() .. "\n")
	
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
	sax.header:write(sax.body:seek() .. "\n")

	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
	sax.body:write((attributes.year or "") .. "\n")
	
	sax.looking_for_part = "Video" -- FILE
end


function sax.episode_start(parser, name, attributes)
	sax.header:write(sax.body:seek() .. "\n")
	
	sax.body:write((attributes.grandparentTitle or "") .. "\n")
	sax.body:write((attributes.index or "") .. "\n")
	sax.body:write((attributes.key or "") .. "\n")
	sax.body:write((attributes.mixedParents or "") .. "\n")
	sax.body:write((attributes.parentIndex or "") .. "\n")
	sax.body:write((attributes.title or "") .. "\n")
	sax.body:write((attributes.type or "") .. "\n")
	
	sax.looking_for_part = "Video" -- FILE
end


function sax.media_container_start(parser, name, attributes)
	sax.header:write((attributes.mixedParents or "") .. "\n")
	sax.header:write((attributes.title1 or "") .. "\n")
	sax.header:write((attributes.title2 or "") .. "\n")
end


function sax.media_container_end(parser, name)
	sax.header:close()
	sax.body:close()
end


function sax.element_start(parser, name, attributes)
	if name == "MediaContainer" then
		sax.media_container_start(parser, name, attributes)
	elseif name == "Directory" then
		sax.directory_start(parser, name, attributes)
	elseif name == "Track" then
		sax.track_start(parser, name, attributes)
	elseif name == "Video" and attributes.type == "movie" then
		sax.movie_start(parser, name, attributes)
	elseif name == "Video" and attributes.type == "episode" then
		sax.episode_start(parser, name, attributes)
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
function sax.init(header, body)
	sax.header = io.open(header, "w")
	sax.body = io.open(body, "w")
	sax.parser = require("lxp").new({
		StartElement = sax.element_start,
		EndElement = sax.element_end
	})
end


function sax.parse(payload)
	for line in io.lines(payload) do
		sax.parser:parse(line)
	end
end

return sax