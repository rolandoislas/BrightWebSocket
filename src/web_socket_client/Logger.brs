' WebSocketLogger.brs
' Copyright (C) 2018 Rolando Islas
' Released under the MIT license
'
' Internal logging utility

' Initialize logging
' Called once to set component global log levels and read the log level config
function init_logging() as void
    m.FATAL = -2
    m.WARN = -1
    m.INFO = 0
    m.DEBUG = 1
    m.EXTRA = 2
    m.VERBOSE = 3
    config_string = readAsciiFile("pkg:/bright_web_socket.json")
    config = parseJson(config_string)
    if config <> invalid
        if config.log_level <> invalid
            m.log_level = _parse_level(config.log_level)
        else
            m.log_info = m.INFO
            printl(m.WARN, "WebSocketLogger: Missing log_level param in pkg:/bright_web_socket.json")
        end if
    else
        m.log_level = m.INFO
        printl(m.WARN, "WebSocketLogger: Missing pkg:/bright_web_socket.json")
    end if
end function

' Log a message
' @param level log level string or integer
' @param msg message to print
function printl(level as object, msg as object) as void
    if _parse_level(level) > m.log_level
        return
    end if
    print "[" + _level_to_string(level) + "] " + msg
end function

' Parse level to a string
' @param level string or integer level
function _level_to_string(level as object) as string
    if type(level) = "roString" or type(level) = "String"
        level = _parse_level(level)
    end if
    if level = -2
        return "FATAL"
    else if level = -1
        return "WARN"
    else if level = 0
        return "INFO"
    else if level = 1
        return "DEBUG"
    else if level = 2
        return "EXTRA"
    else if level = 3
        return "VERBOSE"
    end if
end function

' Parse level to an integer
' @param level string or integer level
function _parse_level(level as object) as integer
    level_string = level.toStr()
    log_level = 0
    if level_string = "FATAL" or level_string = "-2"
        log_level = m.FATAL
    else if level_string = "WARN" or level_string = "-1"
        log_level = m.WARN
    else if level_string = "INFO" or level_string = "0"
        log_level = m.INFO
    else if level_string = "DEBUG" or level_string = "1"
        log_level = m.DEBUG
    else if level_string = "EXTRA" or level_string = "2"
        log_level = m.EXTRA
    else if level_string = "VERBOSE" or level_string = "3"
        log_level = m.VERBOSE
    end if
    return log_level
end function