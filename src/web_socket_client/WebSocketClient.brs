' WebSocketClient.brs
' Copyright (C) 2018 Rolando Islas
' Released under the MIT license
'
' BrightScript task component logic that handles web sockets (RFC 6455)

' Entry point
function init() as void
    ' Constants
    m.REGEX_URL = createObject("roRegex", "(\w+):\/\/([^/:]+)(?::(\d+))?(.*)?", "")
    m.CHARS = "0123456789abcdefghijklmnopqrstuvwxyz".split("")
    m.PORT = createObject("roMessagePort")
    m.NL = chr(13) + chr(10)
    m.HTTP_STATUS_LINE_REGEX = createObject("roRegex", "(HTTP\/\d+(?:.\d)?)\s(\d{3})\s(.*)", "")
    m.HTTP_HEADER_REGEX = createObject("roRegex", "(\w+):\s?(.*)", "")
    m.WS_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    m.FRAME_SIZE = 1024
    m.OPCODE_CONTINUATION = 0
    m.OPCODE_TEXT = 1
    m.OPCODE_BINARY = 2
    m.OPCODE_CLOSE = 8
    m.OPCODE_PING = 9
    m.OPCODE_PONG = 10
    m.BUFFER_SIZE = cint(1024 * 1024 * 0.5)
    ' Fields
    m.top.STATE_CONNECTING = 0
    m.top.STATE_OPEN = 1
    m.top.STATE_CLOSING = 2
    m.top.STATE_CLOSED = 3
    m.top.ready_state = m.top.STATE_CLOSED
    m.top.protocols = []
    m.top.headers = []
    m.top.secure = false
    ' Logging
    init_logging()
    ' Variables
    m.tls = invalid
    m.socket = invalid
    m.sec_ws_key = invalid
    m.handshake = invalid
    m.sent_handshake = false
    m.has_received_handshake = false
    m.data = createObject("roByteArray")
    m.data[m.BUFFER_SIZE] = 0
    m.data_size = 0
    m.frame_data = createObject("roByteArray")
    m.last_ping_time = 0
    m.started_closing = 0
    m.hostname = ""
    ' Event listeners
    m.top.observeField("open", m.PORT)
    m.top.observeField("send", m.PORT)
    m.top.observeField("close", m.PORT)
    m.top.observeField("buffer_size", m.PORT)
    ' Task init
    m.top.functionName = "run"
    m.top.control = "RUN"
end function

' Main task loop
function run() as void
    while true
        msg = wait(0, m.PORT)
        ' Field event
        if type(msg) = "roSGNodeEvent"
            if msg.getField() = "open"
                open(msg.getData())
            else if msg.getField() = "send"
                send(msg.getData())
            else if msg.getField() = "close"
                handle_user_close(msg.getData())
            else if msg.getField() = "buffer_size"
                set_buffer_size(msg.getData())
            end if
        ' Socket event
        else if type(msg) = "roSocketEvent"
            send_handshake()
            read_socket_data()
        end if
        ' Play ping pong
        try_send_ping()
        try_force_close()
    end while
end function

' Set buffer size
function set_buffer_size(size as integer) as void
    if m.top.ready_state <> m.STATE_CLOSED
        printl(m.WARN, "WebSocketClient: Cannot resize buffer on a socket that is not closed")
        return
    else if size < m.FRAME_SIZE
        printl(m.WARN, "WebSocketClient: Cannot set buffer to a size smaller than " + m.FRAME_SIZE.toStr() + " bytes")
        return
    end if
    m.BUFFER_SIZE = size
    m.buffer = createObject("roByteArray")
    m.buffer[m.BUFFER_SIZE] = 0
    m.data_size = 0
end function

' Force close a connection after the close frame has been sent and no response
' was given, after a timeout
function try_force_close() as void
    if m.top.ready_state = m.top.STATE_CLOSING and uptime(0) - m.started_closing >= 30
        close()
    end if
end function

' Try to send a ping
function try_send_ping() as void
    if m.top.ready_state = m.top.STATE_OPEN and uptime(0) - m.last_ping_time >= 1
        if send("", m.OPCODE_PING, true) < 0
            close()
            error(16, "Lost connection")
        end if
        m.last_ping_time = uptime(0)
    end if
end function

' Sends data through the socket
' @param message array - should contain one element of type roString or roArray
'                        cannot exceed 125 bytes if the the specified opcode
'                        is for a control frame
' @param _opcode int - define a **control** opcode data opcodes are determined
'                      by the type of the passed message
' @param silent boolean - does not send on_error event
' @param do_close boolean - if true, a close frame will be sent on errors
function send(message as dynamic, _opcode = -1 as integer, silent = false as boolean, do_close = true as boolean) as integer
    if m.socket = invalid or not m.socket.isWritable()
        printl(m.DEBUG, "WebSocketClient: Failed to send data: socket is closed")
        return -1
    end if
    if m.top.ready_state <> m.top.STATE_OPEN
        printl(m.DEBUG, "WebSocketClient: Failed to send data: connection not open")
        return -1
    end if
    if type(message) = "roString" or type(message) = "String" or type(message) = "roByteArray"
        message = [message]
    end if
    if message.count() <> 1
        printl(m.DEBUG, "WebSocketClient: Failed to send data: too many parameters")
        return -1
    end if
    bytes = createObject("roByteArray")
    opcode = 0
    if type(message[0]) = "roString" or type(message[0]) = "String"
        bytes.fromAsciiString(message[0])
        opcode = m.OPCODE_TEXT
    else if type(message[0]) = "roArray" or type(message[0]) = "roByteArray"
        for each byte in message[0]
            bytes.push(byte)
        end for
        opcode = m.OPCODE_BINARY
    else
        printl(m.DEBUG, "WebSocketClient: Failed to send data: invalid parameter type")
        return -1
    end if
    if _opcode > -1 and (_opcode >> 3) <> 1
        printl(m.DEBUG, "WebSocketClient: Failed to send data: specified opcode was not a control opcode")
        return -1
    else if _opcode > -1
        if bytes.count() > 125
            printl(m.DEBUG, "WebSocketClient: Failed to send data: control frames cannot have a payload larger than 125 bytes")
            return -1
        end if
        opcode = _opcode
    end if
    ' Frame message
    frame_count = bytes.count() \ m.FRAME_SIZE
    if bytes.count() mod m.FRAME_SIZE <> 0 or frame_count = 0
        frame_count++
    end if
    total_sent = 0
    for frame_index = 0 to frame_count - 1
        ' Get sub array of payload bytes
        payload = createObject("roByteArray")
        max = bytes.count() - 1
        if  (frame_index + 1) * m.FRAME_SIZE - 1 < max
            max = (frame_index + 1) * m.FRAME_SIZE - 1
        end if
        for byte_index = frame_index * m.FRAME_SIZE to max
            payload.push(bytes[byte_index])
        end for
        ' Construct frame
        frame = createObject("roByteArray")
        ' FIN(1) RSV1(1) RSV2(1) RSV3(1) opcode(4)
        final = 0
        if frame_index = frame_count - 1
            final = &h80
        end if
        opcode_frame = m.OPCODE_CONTINUATION
        if frame_index = 0
            opcode_frame = opcode
        end if
        frame.push(final or opcode_frame)
        ' mask(1) payload_length(7)
        length_7 = payload.count()
        if payload.count() > &hffff
            length_7 = 127
        else if payload.count() > 125
            length_7 = 126
        end if
        frame.push(&h80 or length_7)
        ' payload_length_continuation(64)
        ' 16 bit uint
        if length_7 = 126
            frame.append(short_to_bytes(payload.count()))
        ' 64 bit uint
        else if length_7 = 127
            frame.append(long_to_bytes(payload.count()))
        end if
        ' masking key(32)
        mask = rnd(&hffff)
        mask_bytes = int_to_bytes(mask)
        frame.append(mask_bytes)
        ' Mask payload
        masked_payload = createObject("roByteArray")
        for byte_index = 0 to payload.count() - 1
            masking_key = mask_bytes[byte_index mod 4]
            byte = payload[byte_index]
            masked_byte = xor(byte, masking_key)
            masked_payload.push(masked_byte)
        end for
        frame.append(masked_payload)
        ' Send frame
        printl(m.VERBOSE, "WebSocketClient: Sending frame: " + frame.toHexString())
        sent = 0
        if m.top.secure
            sent = m.tls.send(m.tls, frame)
        else
            sent = m.socket.send(frame, 0, frame.count())
        end if
        printl(m.VERBOSE, "WebSocketClient: Sent " + sent.toStr() + " bytes")
        total_sent += sent
        if sent <> frame.count()
            if do_close
                close()
            end if
            if not silent
                error(14, "Failed to send data")
            end if
            return total_sent
        end if
    end for
    return total_sent
end function

' Send the initial websocket handshake if it has not been sent
function send_handshake() as void
    if m.socket = invalid or not m.socket.isWritable() or m.sent_handshake or m.handshake = invalid or m.tls.ready_state = m.tls.STATE_CONNECTING
        return
    end if
    if m.top.secure and m.tls.ready_state = m.tls.STATE_DISCONNECTED
        m.tls.connect(m.tls, m.hostname)
    else
        printl(m.VERBOSE, m.handshake)
        sent = 0
        if m.top.secure
            sent = m.tls.send_str(m.tls, m.handshake)
        else
            sent = m.socket.sendStr(m.handshake)
        end if
        printl(m.VERBOSE, "WebSocketClient: Sent " + sent.toStr() + " bytes")
        if sent = -1
            close()
            error(4, "Failed to send data: " + m.socket.status().toStr())
            return
        end if
        m.sent_handshake = true
    end if
end function

' Read socket data
function read_socket_data() as void
    if m.socket = invalid or m.top.ready_state = m.top.STATE_CLOSED or (m.top.secure and m.tls.ready_state = m.tls.STATE_DISCONNECTED)
        return
    end if
    buffer = createObject("roByteArray")
    buffer[1024] = 0
    bytes_received = 0
    if m.socket.isReadable()
        bytes_received = m.socket.receive(buffer, 0, 1024)
    end if
    if bytes_received < 0
        close()
        error(15, "Failed to read from socket")
        return
    end if
    if m.top.secure
        buffer = m.tls.read(m.tls, buffer, bytes_received)
        if buffer = invalid
            close()
            error(17, "TLS error")
            return
        end if
        bytes_received = buffer.count()
    end if
    buffer_index = 0
    for byte_index = m.data_size to m.data_size + bytes_received - 1
            m.data[byte_index] = buffer[buffer_index]
            buffer_index++
    end for
    m.data_size += bytes_received
    m.data[m.data_size] = 0
    ' WebSocket frames
    if m.has_received_handshake
        ' Wait for at least the payload 7-bit size
        if m.data_size < 2
            return
        end if
        final = (m.data[0] >> 7) = 1
        opcode = (m.data[0] and &hf)
        control = (opcode >> 3) = 1
        masked = (m.data[1] >> 7) = 1
        payload_size_7 = m.data[1] and &h7f
        payload_size = payload_size_7
        payload_index = 2
        mask = 0
        if payload_size_7 = 126
            ' Wait for the 16-bit payload size
            if m.data_size < 4
                return
            end if
            payload_size = bytes_to_short(m.data[2], m.data[3])
            payload_index += 2
        else if payload_size_7 = 127
            ' Wait for the 64-bit payload size
            if m.data_size < 10
                return
            end if
            payload_size = bytes_to_long(m.data[2], m.data[3], m.data[4], m.data[5], m.data[6], m.data[7], m.data[8], m.data[9])
            payload_index += 8
        end if
        if masked
            ' Wait for mask int
            if m.data_size < payload_index
                return
            end if
            mask = bytes_to_int(m.data[payload_index], m.data[payload_index + 1], m.data[payload_index + 2], m.data[payload_index + 3])
            payload_index += 4
        end if
        ' Wait for payload
        if m.data_size < payload_index + payload_size
            return
        end if
        payload = createObject("roByteArray")
        for byte_index = payload_index to payload_index + payload_size - 1
            payload.push(m.data[byte_index])
        end for
        ' Handle control frame
        if control
            handle_frame(opcode, payload)
        ' Handle data frame
        else if final
            full_payload = createObject("roByteArray")
            full_payload.append(m.frame_data)
            full_payload.append(payload)
            handle_frame(opcode, full_payload)
            m.frame_data.clear()
        ' Check for continuation frame
        else
            m.frame_data.append(payload)
        end if
        ' Save start of next frame
        if m.data_size > payload_index + payload_size
            data = createObject("roByteArray")
            data.append(m.data)
            m.data.clear()
            for byte_index = payload_index + payload_size to m.data_size - 1
                m.data.push(data[byte_index])
            end for
        else
            m.data.clear()
        end if
    ' HTTP/Handshake
    else
        data = m.data.toAsciiString()
        http_delimiter = m.NL + m.NL
        if data.len() <> data.replace(http_delimiter, "").len()
            split = data.split(http_delimiter)
            message = split[0]
            data = ""
            for split_index = 1 to split.count() - 1
                data += split[split_index]
                if split_index < split.count() - 1 or split[split_index].right(4) = m.NL + m.NL
                    data += m.NL + m.NL
                end if
            end for
            ' Handle the message
            printl(m.VERBOSE, "WebSocketClient: Message: " + message)
            handle_handshake_response(message)
        end if
        m.data.fromAsciiString(data)
    end if
    m.data_size = m.data.count()
    m.data[m.BUFFER_SIZE] = 0
end function

' Handle the handshake message or die trying
function handle_handshake_response(message as string) as void
    lines = message.split(m.NL)
    if lines.count() = 0
        close()
        error(5, "Invalid handshake: Missing status line")
        return
    end if
    ' Check status line
    if not m.HTTP_STATUS_LINE_REGEX.isMatch(lines[0])
        close()
        error(6, "Invalid handshake: Status line malformed")
        return
    end if
    status_line = m.HTTP_STATUS_LINE_REGEX.match(lines[0])
    if status_line[1] <> "HTTP/1.1"
        close()
        error(7, "Invalid handshake: Response version mismatch.  Expected HTTP/1.1, got " + status_line[0])
        return
    end if
    if status_line[2] <> "101"
        close()
        error(8, "Invalid handshake: HTTP status code is not 101: Received " + status_line[2])
        return
    end if
    ' Search headers
    protocol = ""
    for header_line_index = 1 to lines.count() - 1:
        if m.HTTP_HEADER_REGEX.isMatch(lines[header_line_index])
            header = m.HTTP_HEADER_REGEX.match(lines[header_line_index])
            ' Upgrade
            if ucase(header[1]) = "UPGRADE" and ucase(header[2]) <> "WEBSOCKET"
                close()
                error(9, "Invalid handshake: invalid upgrade header: " + header[2])
                return
            ' Connection
            else if ucase(header[1]) = "CONNECTION" and ucase(header[2]) <> "UPGRADE"
                close()
                error(10, "Invalid handshake: invalid connection header: " + header[2])
                return
            ' Sec-WebSocket-Accept
            else if ucase(header[1]) = "SEC-WEBSOCKET-ACCEPT"
                expected_array = createObject("roByteArray")
                expected_array.fromAsciiString(m.sec_ws_key + m.WS_ACCEPT_GUID)
                digest = createObject("roEVPDigest")
                digest.setup("sha1")
                expected = digest.process(expected_array)
                if expected <> header[2].trim()
                    close()
                    error(11, "Invalid handshake: Sec-WebSocket-Accept value is invalid: " + header[2])
                    return
                end if
            ' Sec-WebSocket-Extensions
            else if ucase(header[1]) = "SEC-WEBSOCKET-EXTENSIONS" and header[2] <> ""
                close()
                error(12, "Invalid handshake: Sec-WebSocket-Extensions value is invalid: " + header[2])
                return
            ' Sec-WebSocket-Protocol
            else if ucase(header[1]) = "SEC-WEBSOCKET-PROTOCOL"
                p = header[2].trim()
                was_requested = false
                for each requested_protocol in m.protocols
                    if requested_protocol = p
                        was_requested = true
                    end if
                end for
                if not was_requested
                    close()
                    error(13, "Invalid handshake: Sec-WebSocket-Protocol contains a protocol that was not requested: " + p)
                    return
                end if
                protocol = p
            end if
        end if
    end for
    m.has_received_handshake = true
    state(m.top.STATE_OPEN)
    m.top.setField("on_open", {
        protocol: protocol
    })
end function

' Handle a frame
' @param opcode int opcode
' @param payload roByteArray payload data
function handle_frame(opcode as integer, payload as object) as void
    frame_print  = "WebSocketClient: " + "Received frame:" + m.NL
    frame_print += "  Opcode: " + opcode.toStr() + m.NL
    frame_print += "  Payload: " + payload.toHexString()
    printl(m.VERBOSE, frame_print)
    ' Close
    if opcode = m.OPCODE_CLOSE
        close()
        return
    ' Ping
    else if opcode = m.OPCODE_PING
        send("", m.OPCODE_PONG)
        return
    ' Text
    else if opcode = m.OPCODE_TEXT
        m.top.setField("on_message", {
            type: 0,
            message: payload.toAsciiString()
        })
        return
    ' Data
    else if opcode = m.OPCODE_BINARY
        payload_array = []
        for each byte in payload
            payload_array.push(byte)
        end for
        m.top.setField("on_message", {
            type: 1,
            message: payload_array
        })
        return
    end if
end function

' Generate a 20 character [A-Za-z0-9] random string and base64 encode it
function generate_sec_ws_key() as string
    sec_ws_key = ""
    for char_index = 0 to 19
        char = m.CHARS[rnd(m.CHARS.count()) - 1]
        if rnd(2) = 1
            char = ucase(char)
        end if
        sec_ws_key += char
    end for
    ba = createObject("roByteArray")
    ba.fromAsciiString(sec_ws_key)
    return ba.toBase64String()
end function

' Connect to the specified URL
' @param url_string web socket url to connect
function open(url as string) as void
    if m.top.ready_state <> m.top.STATE_CLOSED
        printl(m.DEBUG, "WebSocketClient: Tried to open a web socket that was already open")
        return
    end if
    if m.REGEX_URL.isMatch(url)
        match = m.REGEX_URL.match(url)
        ws_type = lcase(match[1])
        host = lcase(match[2])
        port = match[3]
        path = match[4]
        m.hostname = host
        ' Port
        if port <> ""
            port = val(port, 10)
        else if ws_type = "wss"
            m.top.secure = true
            port = 443
        else if ws_type = "ws"
            port = 80
        else
            close()
            error(0, "Invalid web socket type specified: " + ws_type)
            return
        end if
        ' Path
        if path = ""
            path = "/"
        end if
        ' WS(S) to HTTP(S)
        scheme = ws_type.replace("ws", "http")
        ' Construct handshake
        m.sec_ws_key = generate_sec_ws_key()
        protocols = ""
        for each proto in m.top.protocols
            protocols += proto + ", "
        end for
        if protocols <> ""
            protocols = protocols.left(len(protocols) - 2)
        end if
        handshake =  "GET " + path + " HTTP/1.1" + m.NL 
        handshake += "Host: " + host + ":" + port.toStr() + m.NL
        handshake += "Upgrade: websocket" + m.NL
        handshake += "Connection: Upgrade" + m.NL
        handshake += "Sec-WebSocket-Key: " + m.sec_ws_key + m.NL
        if protocols <> ""
            handshake += "Sec-WebSocket-Protocol: " + protocols + m.NL
        end if
        ' handshake += "Sec-WebSocket-Extensions: " + m.NL
        handshake += "Sec-WebSocket-Version: 13" + m.NL
        handshake += get_parsed_user_headers()
        handshake += m.NL
        m.handshake = handshake
        ' Create socket
        state(m.top.STATE_CONNECTING)
        address = createObject("roSocketAddress")
        address.setHostName(host)
        address.setPort(port)
        if not address.isAddressValid()
            close()
            error(2, "Invalid hostname")
            return
        end if
        m.data_size = 0
        m.socket = createObject("roStreamSocket")
        m.socket.notifyReadable(true)
        m.socket.notifyWritable(true)
        m.socket.notifyException(true)
        m.socket.setMessagePort(m.PORT)
        m.socket.setSendToAddress(address)
        m.sent_handshake = false
        m.has_received_handshake = false
        m.tls = TlsUtil(m.socket)
        m.tls.set_buffer_size(m.tls, m.BUFFER_SIZE)
        if not m.socket.connect()
            close()
            error(3, "Socket failed to connect: " + m.socket.status().toStr())
            return
        end if
    else
        close()
        error(1, "Invalid URL specified")
    end if
end function

' Parse header array and return a string of headers delimited by CRLF
function get_parsed_user_headers() as string
    if m.top.headers = invalid or m.top.headers.count() = 0 or (m.top.headers.count() mod 2) = 1
        return ""
    end if
    header_string = ""
    for header_index = 0 to m.top.headers.count() - 1 step 2
        header = m.top.headers[header_index]
        value = m.top.headers[header_index + 1]
        header_string += header + ": " + value + m.NL
    end for
    return header_string
end function

' Set ready state
function state(_state as integer) as void
    m.top.setField("ready_state", _state)
end function

' Send an error event
' Sets the on_error field to an associative array with the specified error code
' and message
function error(code as integer, message as string) as void
    printl(m.EXTRA, "WebSocketClient: Error: " + message)
    m.top.setField("on_error", {
        code: code,
        message: message
    })
end function

' Close the socket
' @param code integer -  status code
' @param reason roByteArray - reason
function close(code = 1000 as integer, reason = invalid as object) as void
    if m.socket <> invalid
        ' Send the closing frame
        if m.top.ready_state = m.top.STATE_OPEN
            send_close_frame(code, reason)
            m.started_closing = uptime(0)
            state(m.top.STATE_CLOSING)
        else
            state(m.top.STATE_CLOSED)
            m.top.setField("on_close", " ")
            m.socket.close()
        end if
    else if m.top.ready_state <> m.top.STATE_CLOSED
        state(m.top.STATE_CLOSED)
    end if
end function

' Send a close frame to the server to initiate a close
' @param code integer -  status code
' @param reason roByteArray - reason
function send_close_frame(code, reason)
    message = createObject("roByteArray")
    message.push(code >> 8)
    message.push(code)
    if reason <> invalid
        message.append(reason)
    end if
    send(message, m.OPCODE_CLOSE, true, false)
end function

' Handle a close event field
' @param reason array - array [code as integer, message as roString]
function handle_user_close(params as object) as void
    code = 1000
    reason = createObject("roByteArray")
    if reason.count() > 0
        code = params[0]
        if type(code) <> "Integer" or code > &hffff
            printl(m.DEBUG, "WebSocketClient: close expects value at array index 0 to be a 16-bit integer")
        end if
    end if
    if reason.count() > 1
        message = params[1]
        if type(message) <> "roString" or type(message) <> "String"
            reason.fromAsciiString(message)
        else
            printl(m.DEBUG, "WebSocketClient: close expects value at array index 1 to be a string")
        end if
    end if
    close(code, reason)
end function