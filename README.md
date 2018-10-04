# Plex Media CLIent

[![asciicast](https://asciinema.org/a/lPbaRZjpA4fnMquoZacv3NoPc.png)](https://asciinema.org/a/lPbaRZjpA4fnMquoZacv3NoPc)

**Disclaimer**: the client is a side project and learning experience for me. No guarantee whatsoever is offered about it. The target OS is Linux only.

## Dependencies
* Lua >= 5.1 (LuaJIT too, although there is no reason to use it)
* [lua-http](https://github.com/daurnimator/lua-http)
* [dkjson](https://github.com/LuaDist/dkjson)
* [htmlEntities for Lua](https://github.com/TiagoDanin/htmlEntities-for-lua)
* [mpv](https://mpv.io/) must be installed so that `mpv` is in PATH.

## Installation
`luarocks install --server=http://luarocks.org/dev pmcli`. You will then need to manually make sure mpv is installed.

Alternatively, there is an [AUR package](https://aur.archlinux.org/packages/pmcli-git/) which will install everything.

## Usage
You can launch the client as simply `pmcli`. 
On first start, you will be prompted for configuration and login.

**IMPORTANT**: only login with Plex credentials is supported. If you use Plex via OAuth with your Google or Facebook account, you will have to resort to [manual configuration](https://github.com/Aanok/pmcli/wiki).

Navigation should be straightforward; mind that you can express command ranges as `n1-n2`, command sequences as `s1,s2`, open everything in the current menu with `*` and can always submit `q` to quit immediately.

If you encounter problems, check the [troubleshooting](https://github.com/Aanok/pmcli/wiki/Troubleshooting) page.
