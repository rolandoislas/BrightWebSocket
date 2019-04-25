# WebSocket Bulk Send Server

Web socket server that sends any client that connects to it a lot of message in
 a short time.

# Running

Install the node "ws" library

1. Modify `test/source/Main.brs` so m.SERVER equals `"ws://<local host IP address>:5000"`
1. `npm install` from the build_send folder root
1. `node websocket_bulk_send_server.js`

The server is started on port 5000.
