package = "pmcli"
version = "scm-2"
source = {
   url = "git://github.com/Aanok/pmcli"
}
description = {
   summary = "Command line client for Plex Media Server",
   homepage = "https://github.com/Aanok/pmcli",
   license = "MIT"
}
dependencies = {
   "lua >= 5.3",
   "http",
   "luaexpat"
}
build = {
   type = "builtin",
   modules = {
      ["pmcli.client"] = "src/client.lua",
      ["pmcli.utils"] = "src/utils.lua",
      ["pmcli.sax"] = "src/sax.lua",
      ["pmcli.dkjson"] = "src/dkjson.lua"
   },
   install = {
    bin = {
      ["pmcli"] = "src/pmcli.sh"
    }
   }
}
