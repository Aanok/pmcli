# 0.2
2019/1/??

- Rewrote parsing logic to be faster and use a fixed amount of RAM by streaming to/from disk
- Swapped dkjson for luaexpat. dkjson source file is included repo in order to talk to mpv's socket
- Added server discovery during interactive config (the endpoint returns XML only, hence expat instead of lunajson)
- Added tokenless operation if host is on server whitelist: set `plex_token = ` (empty) or delete the whole line in your config file
- Tidied up temp files
- Fixed a bug where passing --login on an empty config file prompted login twice
- Fixed a bug where menu navigation would work but playback failed when using an invalid token on a whitelisted host
- Some code refactoring


# 0.1.4
2019/1/8

- Made login requests comply to HTTP/2 pseudoheader order spec


# 0.1.3
2018/12/21

- Reworked root menu: playlists, global Recently Added, global On Deck
- Dropped htmlEntities dependency


# 0.1.2
2018/10/7

- Fixed a bug with lack of escaping in mpv --title argument


# 0.1.1
2018/10/3

- Consecutive audio tracks sent for playing are grouped in an mpv playlist;
- Fixed a bug with wrong progress tracking in media items composed of multiple files;
- Added a syntax warning for y/n prompts;
- Started versioning, tracked in the config file.
