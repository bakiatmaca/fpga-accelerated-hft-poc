-- ouch5.lua : Wireshark dissector for Nasdaq OUCH 5.0, with or without SoupBinTCP 3.00
--
-- Layouts follow (nasdaqtrader.com):
--   OUCH 5.0 Order Entry Specification (rev 1.05, 10/7/2025)
--   SoupBinTCP 3.00
--
-- Install : copy to the personal Lua plugins folder (Help > About Wireshark > Folders),
--           then Analyze > Reload Lua Plugins (Ctrl+Shift+L).
-- Use     : right click a packet > Decode As... > TCP port > OUCH5
--           or Preferences > Protocols > OUCH5 > TCP port.
--
-- Framing (preference):
--   Auto       first byte 0x00 -> SoupBinTCP, 'O' -> raw Enter Order
--   SoupBinTCP 2-byte length + packet type; 'U' carries client->host OUCH,
--              'S' carries host->client OUCH (this is how direction is known)
--   Raw        no SoupBinTCP (ouch_sender -R). Only Enter Order ('O') is decoded:
--              without SoupBinTCP the direction of a message is not known and
--              several type letters mean different things in each direction.

local p = Proto("ouch5", "Nasdaq OUCH 5.0")

p.prefs.port    = Pref.uint("TCP port", 34567, "TCP port carrying OUCH 5.0 (0 = use Decode As)")
p.prefs.framing = Pref.enum("Framing", 0, "How OUCH messages are framed on the TCP stream",
    { {1, "Auto", 0}, {2, "SoupBinTCP", 1}, {3, "Raw (no SoupBinTCP)", 2} }, false)

---------------------------------------------------------------------------
-- value tables
---------------------------------------------------------------------------
local SIDE     = { B="Buy", S="Sell", T="Sell short", E="Sell short exempt" }
local TIF      = { ["0"]="Day", ["3"]="IOC", ["5"]="GTX", ["6"]="GTT", E="After hours" }
local DISPLAY  = { Y="Visible", N="Hidden", A="Attributable", Z="Conformant" }
local CAPACITY = { A="Agency", P="Principal", R="Riskless", O="Other" }
local YESNO    = { Y="Yes", N="No" }
local ISO      = { Y="Eligible", N="Not eligible" }
local CROSS    = { N="Continuous market", O="Opening cross", C="Closing cross", H="Halt/IPO",
                   S="Supplemental", R="Retail", E="Extended life", A="After hours close" }
local STATE    = { L="Live", D="Dead" }
local EVENT    = { S="Start of Day", E="End of Day" }
local PRICETYPE= { L="Limit", P="Market peg", M="Midpoint peg", R="Primary peg", Q="Market maker peg", m="Midpoint" }
local RESTATE  = { R="Refresh of display", P="Update of displayed price" }
local BROKEN   = { E="Erroneous", C="Consent", S="Supervisory", X="External" }
local CANCEL   = { D="Regulatory restriction", E="Closed", F="Post Only: price slid for NMS",
                   G="Post Only: contra side displayed order", H="Halted", I="Immediate or Cancel",
                   K="Market Collars", Q="Self Match Prevention", S="Supervisory", T="Timeout",
                   U="User requested", X="Open Protection", Z="System cancel",
                   e="Direct Listing Capital Raise exceeds shares offered" }
local REJECT = {
    [0x01]="Quote Unavailable", [0x02]="Destination Closed", [0x03]="Invalid Display",
    [0x04]="Invalid Max Floor", [0x05]="Invalid Peg Type", [0x06]="Fat Finger", [0x07]="Halted",
    [0x08]="ISO Not Allowed", [0x09]="Invalid Side", [0x0A]="Processing Error",
    [0x0B]="Cancel Pending", [0x0C]="Firm Not Authorized", [0x0D]="Invalid Min Quantity",
    [0x0E]="No Closing Reference Price", [0x0F]="Other", [0x10]="Cancel Not Allowed",
    [0x11]="Pegging Not Allowed", [0x12]="Crossed Market", [0x13]="Invalid Quantity",
    [0x14]="Invalid Cross Order", [0x15]="Replace Not Allowed", [0x16]="Routing Not Allowed",
    [0x17]="Invalid Symbol", [0x18]="Test", [0x19]="Late LOC Too Aggressive",
    [0x1A]="Retail Not Allowed", [0x1B]="Invalid Midpoint Post Only Price",
    [0x1C]="Invalid Destination", [0x1D]="Invalid Price", [0x1E]="Shares Exceed Threshold",
    [0x1F]="Exceeds Maximum Allowed Notional Value", [0x20]="Risk: Aggregate Exposure Exceeded",
    [0x21]="Risk: Market Impact", [0x22]="Risk: Restricted Stock",
    [0x23]="Risk: Short Sell Restricted", [0x24]="Risk: ISO Not Allowed",
    [0x25]="Risk: Exceeds ADV Limit", [0x26]="Risk: Fat Finger", [0x27]="Risk: Locate Required",
    [0x28]="Risk: Symbol Message Rate Restriction", [0x29]="Risk: Port Message Rate Restriction",
    [0x2A]="Risk: Duplicate Message Rate Restriction", [0x2B]="Risk: Short Sell Not Allowed",
    [0x2C]="Risk: Market Order Not Allowed", [0x2D]="Risk: Pre-Market Not Allowed",
    [0x2E]="Risk: Post-Market Not Allowed", [0x2F]="Risk: Short Sell Exempt Not Allowed",
    [0x30]="Risk: Single Order Notional Exceeded", [0x31]="Risk: Max Quantity Exceeded",
    [0x32]="Reg SHO State Not Available", [0x33]="Risk: IPO Market Buy Not Allowed",
    [0x40]="Invalid AIQ" }
local LOGINREJ = { A="Not Authorized", S="Session not available" }

---------------------------------------------------------------------------
-- fields.  kind: s=alpha  u=unsigned int  px=price(8)  spx=signed price(4)  ts=timestamp(8)
---------------------------------------------------------------------------
local F, KIND, MAP = {}, {}, {}
local function def(key, kind, name, map)
    local abbr = "ouch5." .. key
    if     kind == "s"   then F[key] = ProtoField.string(abbr, name)
    elseif kind == "spx" then F[key] = ProtoField.int32(abbr, name, base.DEC)
    elseif kind == "px" or kind == "ts" or kind == "u8" then F[key] = ProtoField.uint64(abbr, name, base.DEC)
    else                      F[key] = ProtoField.uint32(abbr, name, base.DEC) end
    KIND[key], MAP[key] = kind, map
end

def("soup_len",   "u",  "Packet Length")
def("soup_type",  "s",  "Packet Type")
def("soup_user",  "s",  "Username")
def("soup_pass",  "s",  "Password")
def("soup_sess",  "s",  "Session")
def("soup_seq",   "s",  "Sequence Number")
def("soup_rej",   "s",  "Reject Reason Code", LOGINREJ)
def("soup_text",  "s",  "Text")

def("type",       "s",  "Message Type")
def("ts",         "ts", "Timestamp")
def("userref",    "u",  "UserRefNum")
def("origref",    "u",  "OrigUserRefNum")
def("nextref",    "u",  "NextUserRefNum")
def("side",       "s",  "Side", SIDE)
def("qty",        "u",  "Quantity")
def("decr",       "u",  "Decrement Shares")
def("prevented",  "u",  "Quantity Prevented from Trading")
def("symbol",     "s",  "Symbol")
def("price",      "px", "Price")
def("execprice",  "px", "Execution Price")
def("tif",        "s",  "Time In Force", TIF)
def("display",    "s",  "Display", DISPLAY)
def("capacity",   "s",  "Capacity", CAPACITY)
def("iso",        "s",  "InterMarket Sweep Eligibility", ISO)
def("cross",      "s",  "CrossType", CROSS)
def("clordid",    "s",  "ClOrdID")
def("orderref",   "u8", "Order Reference Number")
def("state",      "s",  "Order State", STATE)
def("event",      "s",  "Event Code", EVENT)
def("cancelrsn",  "s",  "Reason", CANCEL)
def("brokenrsn",  "s",  "Reason", BROKEN)
def("restatersn", "s",  "Reason", RESTATE)
def("rejectrsn",  "u",  "Reason", REJECT)
def("liquidity",  "s",  "Liquidity Flag")
def("match",      "u8", "Match Number")
def("aiq",        "s",  "AIQ Strategy")
def("firm",       "s",  "Firm")
def("applen",     "u",  "Appendage Length")
def("opt_len",    "u",  "Option Length")
def("opt_tag",    "u",  "Option Tag")
def("opt_raw",    "s",  "Option Value")
-- optional appendage values (Appendix A)
def("o_secref",   "u8", "SecondaryOrdRefNum")
def("o_firm",     "s",  "Firm")
def("o_minqty",   "u",  "MinQty")
def("o_custtype", "s",  "CustomerType", { R="Retail designated", N="Not retail designated" })
def("o_maxfloor", "u",  "MaxFloor")
def("o_pricetype","s",  "PriceType", PRICETYPE)
def("o_pegoff",   "spx","PegOffset")
def("o_discpx",   "px", "DiscretionPrice")
def("o_disctype", "s",  "DiscretionPriceType", PRICETYPE)
def("o_discoff",  "spx","DiscretionPegOffset")
def("o_postonly", "s",  "PostOnly", { P="Post Only", N="No" })
def("o_randres",  "u",  "RandomReserves")
def("o_route",    "s",  "Route")
def("o_expire",   "u",  "ExpireTime (seconds)")
def("o_tradenow", "s",  "TradeNow", YESNO)
def("o_handle",   "s",  "HandleInst")
def("o_bbo",      "s",  "BBO Weight Indicator")
def("o_dispqty",  "u",  "Display Quantity")
def("o_disppx",   "px", "Display Price")
def("o_group",    "u",  "Group ID")
def("o_located",  "s",  "Shares Located", YESNO)
def("o_locbroker","s",  "Locate Broker")
def("o_side",     "s",  "Side", SIDE)
def("o_refidx",   "u",  "UserRefIdx")
def("o_aiq",      "s",  "AIQ Strategy")
def("o_aiqgroup", "s",  "AIQ Group ID")

local flist = {}
for _, f in pairs(F) do flist[#flist + 1] = f end
p.fields = flist

-- OptionTag -> { field key, value size }
local OPT = {
    [1]={"o_secref",8},   [2]={"o_firm",4},     [3]={"o_minqty",4},   [4]={"o_custtype",1},
    [5]={"o_maxfloor",4}, [6]={"o_pricetype",1},[7]={"o_pegoff",4},   [9]={"o_discpx",8},
    [10]={"o_disctype",1},[11]={"o_discoff",4}, [12]={"o_postonly",1},[13]={"o_randres",4},
    [14]={"o_route",4},   [15]={"o_expire",4},  [16]={"o_tradenow",1},[17]={"o_handle",1},
    [18]={"o_bbo",1},     [22]={"o_dispqty",4}, [23]={"o_disppx",8},  [24]={"o_group",2},
    [25]={"o_located",1}, [26]={"o_locbroker",4},[27]={"o_side",1},   [28]={"o_refidx",1},
    [29]={"o_aiq",1},     [30]={"o_aiqgroup",2} }

---------------------------------------------------------------------------
-- message layouts: fields after the 1-byte type; an optional appendage follows
---------------------------------------------------------------------------
local IN = {   -- client -> host
    O = { "Enter Order", { {"userref",4},{"side",1},{"qty",4},{"symbol",8},{"price",8},{"tif",1},
          {"display",1},{"capacity",1},{"iso",1},{"cross",1},{"clordid",14} } },
    U = { "Replace Order Request", { {"origref",4},{"userref",4},{"qty",4},{"price",8},{"tif",1},
          {"display",1},{"iso",1},{"clordid",14} } },
    X = { "Cancel Order Request", { {"userref",4},{"qty",4} } },
    M = { "Modify Order Request", { {"userref",4},{"side",1},{"qty",4} } },
    C = { "Mass Cancel Request", { {"userref",4},{"firm",4},{"symbol",8} } },
    D = { "Disable Order Entry Request", { {"userref",4},{"firm",4} } },
    E = { "Enable Order Entry Request", { {"userref",4},{"firm",4} } },
    Q = { "Account Query Request", {} },
}
local OUT = {  -- host -> client
    S = { "System Event", { {"ts",8},{"event",1} } },
    A = { "Order Accepted", { {"ts",8},{"userref",4},{"side",1},{"qty",4},{"symbol",8},{"price",8},
          {"tif",1},{"display",1},{"orderref",8},{"capacity",1},{"iso",1},{"cross",1},{"state",1},
          {"clordid",14} } },
    U = { "Order Replaced", { {"ts",8},{"origref",4},{"userref",4},{"side",1},{"qty",4},{"symbol",8},
          {"price",8},{"tif",1},{"display",1},{"orderref",8},{"capacity",1},{"iso",1},{"cross",1},
          {"state",1},{"clordid",14} } },
    C = { "Order Canceled", { {"ts",8},{"userref",4},{"qty",4},{"cancelrsn",1} } },
    D = { "AIQ Canceled", { {"ts",8},{"userref",4},{"decr",4},{"cancelrsn",1},{"prevented",4},
          {"execprice",8},{"liquidity",1},{"aiq",1} } },
    E = { "Order Executed", { {"ts",8},{"userref",4},{"qty",4},{"price",8},{"liquidity",1},{"match",8} } },
    B = { "Broken Trade", { {"ts",8},{"userref",4},{"match",8},{"brokenrsn",1},{"clordid",14} } },
    J = { "Rejected", { {"ts",8},{"userref",4},{"rejectrsn",2},{"clordid",14} } },
    P = { "Cancel Pending", { {"ts",8},{"userref",4} } },
    I = { "Cancel Reject", { {"ts",8},{"userref",4} } },
    T = { "Order Priority Update", { {"ts",8},{"userref",4},{"price",8},{"display",1},{"orderref",8} } },
    M = { "Order Modified", { {"ts",8},{"userref",4},{"side",1},{"qty",4} } },
    R = { "Order Restated", { {"ts",8},{"userref",4},{"restatersn",1} } },
    X = { "Mass Cancel Response", { {"ts",8},{"userref",4},{"firm",4},{"symbol",8} } },
    G = { "Disable Order Entry Response", { {"ts",8},{"userref",4},{"firm",4} } },
    K = { "Enable Order Entry Response", { {"ts",8},{"userref",4},{"firm",4} } },
    Q = { "Account Query Response", { {"ts",8},{"nextref",4} } },
}
local SOUP = { ["+"]="Debug", A="Login Accepted", J="Login Rejected", S="Sequenced Data",
               H="Server Heartbeat", Z="End of Session", L="Login Request",
               U="Unsequenced Data", R="Client Heartbeat", O="Logout Request" }

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function trim(s) return (s:gsub("%s+$", "")) end

local function fmt_price(n)
    local s = string.format("$%.4f", n / 10000)
    if n == 2147483647 or n == 2000000000 then s = s .. ", market order" end
    return s
end

local function fmt_tod(ns)
    local sec = math.floor(ns / 1e9)
    return string.format("%02d:%02d:%02d.%09d", math.floor(sec / 3600), math.floor(sec / 60) % 60,
                         sec % 60, ns - sec * 1e9)
end

-- add one field; returns its value as a Lua string/number for the summary line
local function add(tree, tvb, key, off, len)
    local r, kind, map = tvb:range(off, len), KIND[key], MAP[key]
    local item = tree:add(F[key], r)
    if kind == "s" then
        local v = trim(r:string())
        if map and map[v] then item:append_text(" (" .. map[v] .. ")") end
        return v
    elseif kind == "px" then
        local n = r:uint64():tonumber()
        item:append_text(" (" .. fmt_price(n) .. ")")
        return n
    elseif kind == "spx" then
        local n = r:int()
        item:append_text(string.format(" (%.4f)", n / 10000))
        return n
    elseif kind == "ts" then
        local n = r:uint64():tonumber()
        item:append_text(" (" .. fmt_tod(n) .. ")")
        return n
    elseif kind == "u8" then
        return r:uint64():tonumber()
    end
    local n = r:uint()
    if map then item:append_text(" (" .. (map[n] or "unknown") .. ")") end
    return n
end

local function dissect_appendage(tree, tvb, off, stop)
    local applen = tvb:range(off, 2):uint()
    tree:add(F.applen, tvb:range(off, 2))
    off = off + 2
    if applen == 0 then return end
    if off + applen > stop then
        tree:add(p, tvb:range(off, stop - off), "Appendage truncated (length " .. applen .. ")")
        return
    end
    local sub = tree:add(p, tvb:range(off, applen), "Optional Appendage")
    local aend = off + applen
    while off + 2 <= aend do
        local elen = tvb:range(off, 1):uint()          -- length of tag + value
        local tag  = tvb:range(off + 1, 1):uint()
        if elen < 1 or off + 1 + elen > aend then
            sub:add(p, tvb:range(off, aend - off), "Malformed TagValue element")
            return
        end
        local o = OPT[tag]
        local t = sub:add(p, tvb:range(off, 1 + elen), "Option " .. tag .. (o and "" or " (unknown)"))
        t:add(F.opt_len, tvb:range(off, 1))
        t:add(F.opt_tag, tvb:range(off + 1, 1))
        if o and o[2] == elen - 1 then
            add(t, tvb, o[1], off + 2, elen - 1)
        elseif elen > 1 then
            t:add(p, tvb:range(off + 2, elen - 1), "Value (" .. (elen - 1) .. " bytes, not decoded)")
        end
        off = off + 1 + elen
    end
end

-- one OUCH message occupying [off, off+len); tbl is IN or OUT. Returns summary text.
local function dissect_ouch(tree, tvb, off, len, tbl)
    local t = tvb:range(off, 1):string()
    local m = tbl[t]
    local name = m and m[1] or ("Unknown message '" .. t .. "'")
    local sub = tree:add(p, tvb:range(off, len), "OUCH 5.0: " .. name)
    sub:add(F.type, tvb:range(off, 1)):append_text(" (" .. name .. ")")
    if not m then return name end

    local stop, o, v = off + len, off + 1, {}
    for _, fd in ipairs(m[2]) do
        if o + fd[2] > stop then
            sub:add(p, tvb:range(o, stop - o), "Message truncated")
            return name .. " [truncated]"
        end
        v[fd[1]] = add(sub, tvb, fd[1], o, fd[2])
        o = o + fd[2]
    end
    if stop - o >= 2 then dissect_appendage(sub, tvb, o, stop) end

    local s = name
    if v.userref then s = s .. " ref=" .. v.userref end
    if v.nextref then s = s .. " next=" .. v.nextref end
    if v.side    then s = s .. " " .. (SIDE[v.side] or v.side) end
    if v.qty     then s = s .. " " .. v.qty end
    if v.symbol and v.symbol ~= "" then s = s .. " " .. v.symbol end
    if v.price   then s = s .. " @" .. string.format("%.4f", v.price / 10000) end
    if v.tif     then s = s .. " " .. (TIF[v.tif] or v.tif) end
    if v.rejectrsn then s = s .. " (" .. (REJECT[v.rejectrsn] or v.rejectrsn) .. ")" end
    if v.cancelrsn then s = s .. " (" .. (CANCEL[v.cancelrsn] or v.cancelrsn) .. ")" end
    if v.event   then s = s .. " " .. (EVENT[v.event] or v.event) end
    return s
end

-- one SoupBinTCP packet occupying [off, off+len). Returns summary text.
local function dissect_soup(tree, tvb, off, len)
    local t = tvb:range(off + 2, 1):string()
    local name = SOUP[t] or ("Unknown packet '" .. t .. "'")
    local sub = tree:add(p, tvb:range(off, 3), "SoupBinTCP: " .. name)
    sub:add(F.soup_len, tvb:range(off, 2))
    sub:add(F.soup_type, tvb:range(off + 2, 1)):append_text(" (" .. name .. ")")
    local po, pl = off + 3, len - 3
    if t == "L" and pl >= 46 then
        add(sub, tvb, "soup_user", po, 6);       add(sub, tvb, "soup_pass", po + 6, 10)
        add(sub, tvb, "soup_sess", po + 16, 10); add(sub, tvb, "soup_seq", po + 26, 20)
    elseif t == "A" and pl >= 30 then
        add(sub, tvb, "soup_sess", po, 10);      add(sub, tvb, "soup_seq", po + 10, 20)
    elseif t == "J" and pl >= 1 then
        add(sub, tvb, "soup_rej", po, 1)
    elseif t == "+" and pl >= 1 then
        add(sub, tvb, "soup_text", po, pl)
    elseif (t == "U" or t == "S") and pl >= 1 then
        return dissect_ouch(tree, tvb, po, pl, t == "U" and IN or OUT)
    end
    return name
end

---------------------------------------------------------------------------
-- TCP stream framing
---------------------------------------------------------------------------
local RAW_ORDER_LEN = 47   -- Enter Order without appendage; Appendage Length at offset 45

-- returns: framing ("soup"/"raw"), total PDU length; length -1 = need more bytes; nil = cannot frame
local function pdu_len(tvb, off, avail)
    local mode = p.prefs.framing
    local b = tvb:range(off, 1):uint()
    if mode == 0 then mode = (b == 0) and 1 or 2 end
    if mode == 1 then
        if avail < 2 then return "soup", -1 end
        local n = tvb:range(off, 2):uint()
        if n == 0 then return nil end
        return "soup", 2 + n
    end
    if b ~= 0x4f then return nil end
    if avail < RAW_ORDER_LEN then return "raw", -1 end
    return "raw", RAW_ORDER_LEN + tvb:range(off + 45, 2):uint()
end

function p.dissector(tvb, pinfo, tree)
    local total = tvb:len()
    if total == 0 or total ~= tvb:reported_len() then return 0 end   -- sliced capture
    pinfo.cols.protocol = "OUCH5"
    local root = tree:add(p, tvb:range(0, total))
    local info, off = {}, 0
    while off < total do
        local avail = total - off
        local framing, need = pdu_len(tvb, off, avail)
        if not framing then
            root:add(p, tvb:range(off, avail), "Undecoded data (" .. avail .. " bytes)")
            info[#info + 1] = "undecoded"
            break
        end
        if need < 0 or need > avail then      -- ask TCP for the rest of this PDU
            pinfo.desegment_offset = off
            pinfo.desegment_len = (need < 0) and DESEGMENT_ONE_MORE_SEGMENT or (need - avail)
            break
        end
        if framing == "soup" then
            info[#info + 1] = dissect_soup(root, tvb, off, need)
        else
            info[#info + 1] = dissect_ouch(root, tvb, off, need, IN)
        end
        off = off + need
    end
    if #info > 0 then pinfo.cols.info = table.concat(info, "; ") end
    return total
end

---------------------------------------------------------------------------
-- registration
---------------------------------------------------------------------------
local tcp_table = DissectorTable.get("tcp.port")
local cur_port = 0
pcall(function() tcp_table:add_for_decode_as(p) end)

local function apply_port()
    if cur_port ~= 0 then tcp_table:remove(cur_port, p) end
    cur_port = p.prefs.port
    if cur_port ~= 0 then tcp_table:add(cur_port, p) end
end
function p.prefs_changed() apply_port() end
function p.init() apply_port() end
