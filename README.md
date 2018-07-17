# Plex Media CLIent

## Dependencies
* `luarocks install lua-http`
* `luarocks install xml2lua`
* `luarocks install html-entities`
* `mpv` must be in PATH.

## Usage
The client is in an extremely immature state and barely functional. No guarantee whatsoever is offered about it. The target OS is Linux only.

Open the script and edit `local BASE_ADDR` to point to your server, including the relevant port number. For the moment, **the server must be in a LAN with the client**.

Once launched the client (`lua pmcli.lua`), navigation should be straightforward.
