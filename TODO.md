* Debug flag to print JSON contents and other info
* ***Robust error handling***
* Per-session cache of already requested directories to reduce traffic and improve response time
* Global search (will require command syntax amendment; might require item tag refactoring)
* Make mpv work on playlists of adjacent items instead of launching and closing one process each time
* Look into websocket interface?
* Support external subtitle files for video items.
    To do this, open the key for the Video element. You'll get a bunch of relevant Stream elements in the reply, including external subs.
    The streamid for subtitle Stream elements can be used to straight up pull the sub file (at https://addr:port/library/streams/$streamid), passing it to mpv as --sub-files=$1[:$2]*
    mpv does not complain if you add like so a subtitle that's already included in the main container :)
* Support transcoding (o mama!)
