# Plex Media CLIent

## Dependencies
* Lua >= 5.3 (*might* work on 5.1+ but I haven't tested yet)
* `luarocks install http`
* `luarocks install xml2lua`
* `luarocks install html-entities`
* `mpv` must be in PATH.

## Installation
```
git clone https://github.com/Aanok/pmcli.git
sudo make install
```

### Uninstallation
`sudo make uninstall`

## Usage
The client is in a very immature state and barely functional. No guarantee whatsoever is offered about it. The target OS is Linux only.

First we need to recover a valid authorization token. Maybe in the future PMCLI will provide its own authentication, but not for the moment.
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

Once launched the client, navigation should be straightforward.
