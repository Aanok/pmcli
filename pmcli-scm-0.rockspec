package = "pmcli"
version = "scm-0"
source = {
   url = "https://github.com/Aanok/pmcli.git"
}
description = {
   summary = "Command line client for Plex Media Server",
   homepage = "https://github.com/Aanok/pmcli",
   license = "MIT"
}
dependencies = {
   "lua >= 5.1",
   "http",
   "xml2lua",
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
