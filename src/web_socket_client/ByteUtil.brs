' ByteUtil.brs
' Copyright (C) 2018 Rolando Islas
' Released under the MIT license
'
' Byte array operation related utilities

' Convert network ordered bytes to a short
function bytes_to_short(b1 as integer, b2 as integer)
    return (b1 << 8) or (b2 and &hff)
end function

' Convert network ordered bytes to a long
function bytes_to_long(b1 as integer, b2 as integer, b3 as integer, b4 as integer, b5 as integer, b6 as integer, b7 as integer, b8 as integer)
    return ((b1 and &hff) << 24) or ((b2 and &hff) << 16) or ((b3 and &hff) << 8) or (b4 and &hff) or ((b5 and &hff) << 24) or ((b6 and &hff) << 16) or ((b7 and &hff) << 8) or (b8 and &hff)
end function

' Convert network ordered bytes to an int
function bytes_to_int(b1 as integer, b2 as integer, b3 as integer, b4 as integer)
    return (b1 << 24) or ((b2 and &hff) << 16) or ((b3 and &hff) << 8) or (b4 and &hff)
end function