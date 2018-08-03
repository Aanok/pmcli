# Plex Media CLIent
**DISCLAIMER**: the client sort of works but it is a side project and a learning experience for me. No guarantee whatsoever is offered about it. The target OS is Linux only.

## Dependencies
* Lua >= 5.1 (LuaJIT too, although there is no reason to use it)
* [lua-http](https://github.com/daurnimator/lua-http)
* [xml2lua](https://github.com/manoelcampos/Xml2Lua)
* [htmlEntities for Lua](https://github.com/TiagoDanin/htmlEntities-for-lua)
* `mpv` must be in PATH.

Please note Lua dependencies are pulled automatically by luarocks but mpv must be manually installed.

## Installation
`luarocks install --server=http://luarocks.org/dev pmcli`

### Uninstallation
`luarocks remove pmcli`

## Usage
You can launch the client as simply `pmcli`. 
On first start, you will be prompted for configuration and login.

**IMPORTANT**: only login with Plex credentials is supported. If you use Plex via OAuth with your Google or Twitter account, you will have to resort to [manual configuration](https://github.com/Aanok/pmcli/wiki).

Navigation should be straightforward; mind that you can express command ranges as `n1-n2`, command sequences as `s1,s2` and can always submit `q` to quit immediately.

Note that PMCLI is mostly intended to be a music player.
