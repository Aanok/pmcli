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
   "lua >= 5.1",
   "http",
   "dkjson",
   "html-entities",
   "lpeg"
}
build = {
   type = "builtin",
   modules = {
      ["pmcli.client"] = "src/client.lua",
      ["pmcli.utils"] = "src/utils.lua"
   },
   install = {
    bin = {
      ["pmcli"] = "src/pmcli.sh"
    }
   }
}
