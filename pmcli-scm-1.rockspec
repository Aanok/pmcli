package = "pmcli"
version = "scm-1"
source = {
   url = "git://github.com/Aanok/pmcli"
}
description = {
   summary = "Command line client for Plex Media Server",
   homepage = "https://github.com/Aanok/pmcli",
   license = "MIT"
}
dependencies = {
   "lua = 5.2",
   "http",
   "dkjson",
   "lpeg"
}
build = {
   type = "builtin",
   modules = {
      ["pmcli.utils"] = "src/utils.lua",
      ["pmcli.mpv_script"] = "src/mpv_script.lua"
   },
   install = {
    bin = {
      ["pmcli-mpv"] = "src/pmcli.sh"
    }
   }
}
