os.execute("stty sane")

-- caveat insanity: options are TYPE-CHECKED by mpv!
local options = {
	help = false,
	config = "",
	login = false
	}
require("mp.options").read_options(options, "pmcli")

require("pmcli.client").new(options):run()