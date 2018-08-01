# Plex Media CLIent
**DISCLAIMER**: the client is in a very immature state and barely functional. No guarantee whatsoever is offered about it. The target OS is Linux only.

## Dependencies
* Lua >= 5.1 (LuaJIT too, although there is no reason to use it)
* [lua-http](https://github.com/daurnimator/lua-http)
* [xml2lua](https://github.com/manoelcampos/Xml2Lua)
* [htmlEntities for Lua](https://github.com/TiagoDanin/htmlEntities-for-lua)
* `mpv` must be in PATH.

Please note Lua dependencies are pulled automatically by luarocks but mpv must be manually installed.

## Installation
`luarocks install`

### Uninstallation
`luarocks remove pmcli`

## Usage
First we need to recover a valid authorization token. In the future PMCLI will provide its own authentication, but not for the moment.
1. Launch Plex from a web browser (through app.plex.tv or directly, it doesn't matter).
2. Open the Developer Tools: on Firefox and Chromiums you can press F12.
3. Go to Local Storage > your current page and look for "myPlexAccessToken" and copy the contents.

![token get](https://i.imgur.com/cnt8m55.png)

Create a file called `pmcli_config.lua` in your `$XDG_CONFIG_HOME` (or `$HOME/.config` if that is not set). Make sure to `chmod 600 pmcli_config.lua`.

Fill the file as follows:
```
options.plex_token = "the_token"
options.base_addr = "plex_server_address:port"
```

Please mind the quotes, those need to be strings. The address should look something like `https://example.com:32400`.
Additionally, you might add `options.require_hostname_validation = false` if the address listed on your webserver's certificate isn't the same your Plex Media Server's (e.g. if you redirect to a local address).

You can launch the client as simply `pmcli`. Navigation should be straightforward; mind that you can express command ranges as `n1-n2`, command sequences as `s1,s2` and can always submit `q` to quit immediately.

Note that PMCLI is mostly intended to be a music player.
