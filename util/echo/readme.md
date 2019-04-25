# WebSocket Echo Server

Tiny node script to create a websocket echo server

# Running

Install the node "ws" library

1. Modify `test/source/Main.brs` so m.SERVER equals `"ws://<local host IP address>:5000"`
1. `npm install` from the echo folder root
1. `node websocket_echo_server.js`

The server is started on port 5000 and echos both binary and text frames.
