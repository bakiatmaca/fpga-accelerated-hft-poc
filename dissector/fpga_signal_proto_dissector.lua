-- fpga_signal_proto_dissector.lua
-- Wireshark dissector for the 33-byte FPGA custom signal message over UDP
--
-- Layout (big-endian):
--   off len field
--   0   1   Magic
--   1   1   MsgType
--   2   6   Timestamp (epoch ms)
--   8   8   OrderRef
--   16  1   Side (ASCII)
--   17  4   Shares
--   21  8   Stock (ASCII)
--   29  4   Price

local MSG_LEN = 33

local proto = Proto("fpgacustomsignal", "FPGA Custom Signal Protocol")

local f = proto.fields
f.magic  = ProtoField.uint8 ("fpgacustomsignal.magic",  "Magic",          base.HEX)
f.mtype  = ProtoField.uint8 ("fpgacustomsignal.mtype",  "MsgType",        base.HEX)
f.ts     = ProtoField.uint64("fpgacustomsignal.ts",     "Timestamp (ms)", base.DEC)
f.ts_abs = ProtoField.absolute_time("fpgacustomsignal.ts_abs", "Timestamp", base.LOCAL)
f.oref   = ProtoField.uint64("fpgacustomsignal.oref",   "OrderRef",       base.DEC)
f.side   = ProtoField.string("fpgacustomsignal.side",   "Side")
f.shares = ProtoField.uint32("fpgacustomsignal.shares", "Shares",         base.DEC)
f.stock  = ProtoField.string("fpgacustomsignal.stock",  "Stock")
f.price  = ProtoField.uint32("fpgacustomsignal.price",  "Price",          base.DEC)

proto.prefs.port = Pref.uint("UDP port", 1235, "UDP port of the protocol")

local function dissect_one(tvb, tree, off)
    local sub = tree:add(proto, tvb(off, MSG_LEN), "FPGA Custom Signal Message")

    local r_ts    = tvb(off + 2, 6)
    local r_oref  = tvb(off + 8, 8)
    local r_side  = tvb(off + 16, 1)
    local r_stock = tvb(off + 21, 8)

    local ts_u64 = r_ts:uint64()
    local ts_ms  = ts_u64:tonumber()
    local side   = r_side:string()
    local shares = tvb(off + 17, 4):uint()
    local stock  = r_stock:string():gsub("[%s%z]+$", "")
    local price  = tvb(off + 29, 4):uint()
    local secs   = math.floor(ts_ms / 1000)

    sub:add(f.magic,  tvb(off, 1))
    sub:add(f.mtype,  tvb(off + 1, 1))
    sub:add(f.ts,     r_ts, ts_u64)
    sub:add(f.ts_abs, r_ts, NSTime(secs, (ts_ms - secs * 1000) * 1000000))
    sub:add(f.oref,   r_oref, r_oref:uint64())
    sub:add(f.side,   r_side, side)
    sub:add(f.shares, tvb(off + 17, 4))
    sub:add(f.stock,  r_stock, stock)
    sub:add(f.price,  tvb(off + 29, 4))

    return string.format("%s %d %s @ %d", side, shares, stock, price)
end

function proto.dissector(tvb, pinfo, tree)
    local len = tvb:len()
    -- if len < MSG_LEN then return 0 end
    if len < MSG_LEN or len % MSG_LEN ~= 0 then return 0 end

    pinfo.cols.protocol = "FpgaCustomSignal"

    local infos, off = {}, 0
    while off + MSG_LEN <= len do
        infos[#infos + 1] = dissect_one(tvb, tree, off)
        off = off + MSG_LEN
    end

    pinfo.cols.info = table.concat(infos, " | ")
    return off
end

local udp_table = DissectorTable.get("udp.port")
local current_port = proto.prefs.port
udp_table:add(current_port, proto)

function proto.prefs_changed()
    if current_port ~= proto.prefs.port then
        udp_table:remove(current_port, proto)
        current_port = proto.prefs.port
        udp_table:add(current_port, proto)
    end
end
