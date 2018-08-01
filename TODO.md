* Debug flag to print XML contents and other info
* Robust error handling
* Config file right now is a Lua file and blindly interpreted: that's a huge security risk. Replace with an adhoc "term = value" .ini style file.
* Use mpv's JSON IPC to get playback position and notify PMS of partial viewing.
* Per-session cache of already requested directories to reduce traffic.
* Look into websocket interface?
