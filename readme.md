# BrightWebSocket

A SceneGraph websocket client library written in BrightScript

**This repo is no longer maintained. See [This fork](https://github.com/SuitestAutomation/BrightWebSocket) for an actively maintained repo.**

# RFC 6455

Follows [RFC 6455](https://tools.ietf.org/html/rfc6455)

Notes:

- Uses ASCII instead of UTF-8 for string operations
- Does not support secure web sockets at this time

# Installation

The contents of the "src" folder in the repository's root should be placed
 in the "components" folder of a SceneGraph Roku app.

# Using the Library

The client follows the
 [HTML WebSocket interface](https://html.spec.whatwg.org/multipage/web-sockets.html#the-websocket-interface),
 modified to work with BrightScript conventions. Those familiar with browser
 (JavaScript) WebSocket implementations should find this client similar.

Example:

```brightscript
function init() as void
    m.ws = createObject("roSGNode", "WebSocketClient")
    m.ws.observeField("on_open", "on_open")
    m.ws.observeFiled("on_message", "on_message")
    m.ws.open = "ws://echo.websocket.org/"
end function

function on_open(event as object) as void
    m.ws.send = ["Hello World"]
end function

function on_message(event as object) as void
    print event.getData().message
end function
```

For a working sample app see the "test" folder. Its contents can be zipped for
 installation as a dev channel on a Roku using `cd test && make install`

# License

The MIT License. See license.txt.
