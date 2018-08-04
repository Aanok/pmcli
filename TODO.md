* Debug flag to print XML contents and other info
* Robust error handling
* Use mpv's JSON IPC to get playback position and notify PMS of partial viewing.
```lua
socket = require("cqueues.socket")
mpv_socket = socket.connect({ path = "/tmp/mpvsocket" }) -- we'll actually use a tmpfile
-- handler
repeat
	msg = mpv_socket:read()
	do_stuff(msg)
	--[[
	replies we care about:
		{"data":39.949123,"error":"success"} for playback-time
		{"event":"end-file"}
		{"event":"start-file"}
	--]]
until msg == nil

-- poller
every_5_seconds_do
	mpv_socket:write('{ "command": ["get_property", "playback-time"] }\n\r')
end

mpv_socket:close()
```
* Per-session cache of already requested directories to reduce traffic.
* Search
* Look into websocket interface?
