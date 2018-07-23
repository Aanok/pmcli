* Debug flag to print XML contents and other info
* Robust error handling
* Config file right now is a Lua file and blindly interpreted: that's a huge security risk. Replace with an adhoc "term = value" .ini style file.
* Rewrite the command parser. It's embarrassing.
* Use mpv's JSON IPC to get playback position and notify PMS of partial viewing (need to figure out the latter from their API)
