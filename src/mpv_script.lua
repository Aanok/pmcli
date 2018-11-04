--os.execute("stty sane")

-- caveat insanity: options are TYPE-CHECKED by mpv!
local options = {
	help = false,
	config = "",
	login = false
	}
require("mp.options").read_options(options, "pmcli")

-- create client, refer to it as upvalue from event handlers so we can
-- properly invoke methods
local client = require("pmcli.client").new(options)
mp.register_event("idle", function(event) client:menu(event) end)
