-- Nasdaq TotalView-ITCH 5.0 over MoldUDP64 dissector for Wireshark

local UDP_PORT = 1234

local mold = Proto("mold64i", "MoldUDP64 (Lua)")
local itch = Proto("itch50", "Nasdaq TotalView-ITCH 5.0 (Lua)")

local mf = {
  session = ProtoField.string("mold64i.session", "Session"),
  seq     = ProtoField.uint64("mold64i.seq", "Sequence Number"),
  count   = ProtoField.uint16("mold64i.count", "Message Count"),
}
mold.fields = { mf.session, mf.seq, mf.count }

local KLEN = { c = 1, u16 = 2, u32 = 4, u64 = 8, ts = 6, p4 = 4, p8 = 8 }

local COMMON = {
  { "locate",    "Stock Locate",    "u16" },
  { "tracking",  "Tracking Number", "u16" },
  { "timestamp", "Timestamp (ns)",  "ts"  },
}

local MSG = {
  S = { "System Event", {
        { "event_code", "Event Code", "c" } } },
  R = { "Stock Directory", {
        { "stock", "Stock", "s", 8 },
        { "market_category", "Market Category", "c" },
        { "fin_status", "Financial Status Indicator", "c" },
        { "round_lot", "Round Lot Size", "u32" },
        { "round_lots_only", "Round Lots Only", "c" },
        { "issue_class", "Issue Classification", "c" },
        { "issue_subtype", "Issue Sub-Type", "s", 2 },
        { "authenticity", "Authenticity", "c" },
        { "short_sale_thr", "Short Sale Threshold Indicator", "c" },
        { "ipo_flag", "IPO Flag", "c" },
        { "luld_tier", "LULD Reference Price Tier", "c" },
        { "etp_flag", "ETP Flag", "c" },
        { "etp_leverage", "ETP Leverage Factor", "u32" },
        { "inverse", "Inverse Indicator", "c" } } },
  H = { "Stock Trading Action", {
        { "stock", "Stock", "s", 8 },
        { "trading_state", "Trading State", "c" },
        { "reserved", "Reserved", "c" },
        { "reason", "Reason", "s", 4 } } },
  Y = { "Reg SHO Restriction", {
        { "stock", "Stock", "s", 8 },
        { "regsho_action", "Reg SHO Action", "c" } } },
  L = { "Market Participant Position", {
        { "mpid", "MPID", "s", 4 },
        { "stock", "Stock", "s", 8 },
        { "primary_mm", "Primary Market Maker", "c" },
        { "mm_mode", "Market Maker Mode", "c" },
        { "mm_state", "Market Participant State", "c" } } },
  V = { "MWCB Decline Level", {
        { "mwcb_level1", "Level 1", "p8" },
        { "mwcb_level2", "Level 2", "p8" },
        { "mwcb_level3", "Level 3", "p8" } } },
  W = { "MWCB Status", {
        { "breached_level", "Breached Level", "c" } } },
  K = { "IPO Quoting Period Update", {
        { "stock", "Stock", "s", 8 },
        { "ipo_release_time", "IPO Quotation Release Time", "u32" },
        { "ipo_release_qual", "IPO Quotation Release Qualifier", "c" },
        { "ipo_price", "IPO Price", "p4" } } },
  J = { "LULD Auction Collar", {
        { "stock", "Stock", "s", 8 },
        { "auction_ref_price", "Auction Collar Reference Price", "p4" },
        { "upper_collar", "Upper Auction Collar Price", "p4" },
        { "lower_collar", "Lower Auction Collar Price", "p4" },
        { "collar_ext", "Auction Collar Extension", "u32" } } },
  h = { "Operational Halt", {
        { "stock", "Stock", "s", 8 },
        { "market_code", "Market Code", "c" },
        { "halt_action", "Operational Halt Action", "c" } } },
  A = { "Add Order", {
        { "order_ref", "Order Reference", "u64" },
        { "side", "Buy/Sell", "c" },
        { "shares", "Shares", "u32" },
        { "stock", "Stock", "s", 8 },
        { "price", "Price", "p4" } } },
  F = { "Add Order w/ MPID", {
        { "order_ref", "Order Reference", "u64" },
        { "side", "Buy/Sell", "c" },
        { "shares", "Shares", "u32" },
        { "stock", "Stock", "s", 8 },
        { "price", "Price", "p4" },
        { "attribution", "Attribution", "s", 4 } } },
  E = { "Order Executed", {
        { "order_ref", "Order Reference", "u64" },
        { "exec_shares", "Executed Shares", "u32" },
        { "match", "Match Number", "u64" } } },
  C = { "Order Executed w/ Price", {
        { "order_ref", "Order Reference", "u64" },
        { "exec_shares", "Executed Shares", "u32" },
        { "match", "Match Number", "u64" },
        { "printable", "Printable", "c" },
        { "exec_price", "Execution Price", "p4" } } },
  X = { "Order Cancel", {
        { "order_ref", "Order Reference", "u64" },
        { "cancel_shares", "Cancelled Shares", "u32" } } },
  D = { "Order Delete", {
        { "order_ref", "Order Reference", "u64" } } },
  U = { "Order Replace", {
        { "orig_ref", "Original Order Reference", "u64" },
        { "new_ref", "New Order Reference", "u64" },
        { "shares", "Shares", "u32" },
        { "price", "Price", "p4" } } },
  P = { "Trade (Non-Cross)", {
        { "order_ref", "Order Reference", "u64" },
        { "side", "Buy/Sell", "c" },
        { "shares", "Shares", "u32" },
        { "stock", "Stock", "s", 8 },
        { "price", "Price", "p4" },
        { "match", "Match Number", "u64" } } },
  Q = { "Cross Trade", {
        { "cross_shares", "Shares", "u64" },
        { "stock", "Stock", "s", 8 },
        { "cross_price", "Cross Price", "p4" },
        { "match", "Match Number", "u64" },
        { "cross_type", "Cross Type", "c" } } },
  B = { "Broken Trade", {
        { "match", "Match Number", "u64" } } },
  I = { "NOII", {
        { "paired_shares", "Paired Shares", "u64" },
        { "imbalance_shares", "Imbalance Shares", "u64" },
        { "imbalance_dir", "Imbalance Direction", "c" },
        { "stock", "Stock", "s", 8 },
        { "far_price", "Far Price", "p4" },
        { "near_price", "Near Price", "p4" },
        { "ref_price", "Current Reference Price", "p4" },
        { "cross_type", "Cross Type", "c" },
        { "price_var", "Price Variation Indicator", "c" } } },
  N = { "Retail Price Improvement Indicator", {
        { "stock", "Stock", "s", 8 },
        { "rpii", "Interest Flag", "c" } } },
  O = { "Direct Listing w/ Capital Raise", {
        { "stock", "Stock", "s", 8 },
        { "open_eligibility", "Open Eligibility Status", "c" },
        { "min_price", "Minimum Allowable Price", "p4" },
        { "max_price", "Maximum Allowable Price", "p4" },
        { "near_exec_price", "Near Execution Price", "p4" },
        { "near_exec_time", "Near Execution Time", "u64" },
        { "lower_collar", "Lower Price Range Collar", "p4" },
        { "upper_collar", "Upper Price Range Collar", "p4" } } },
}

local DESC = {
  side          = { B = "Buy", S = "Sell" },
  event_code    = { O = "Start of Messages", S = "Start of System Hours",
                    Q = "Start of Market Hours", M = "End of Market Hours",
                    E = "End of System Hours", C = "End of Messages" },
  trading_state = { H = "Halted", P = "Paused", Q = "Quotation Only", T = "Trading" },
  printable     = { Y = "Printable", N = "Non-Printable" },
  cross_type    = { O = "Opening", C = "Closing", H = "IPO/Halted", I = "Intraday" },
  imbalance_dir = { B = "Buy", S = "Sell", N = "No Imbalance", O = "Insufficient Orders" },
}

local F, flist = {}, {}
local function mkfield(key, label, kind)
  if F[key] then return end
  local abbr = "itch50." .. key
  local f
  if kind == "c" or kind == "s" then f = ProtoField.string(abbr, label)
  elseif kind == "u16" then f = ProtoField.uint16(abbr, label)
  elseif kind == "u32" then f = ProtoField.uint32(abbr, label)
  elseif kind == "u64" or kind == "ts" then f = ProtoField.uint64(abbr, label)
  else f = ProtoField.double(abbr, label) end
  F[key] = f
  flist[#flist + 1] = f
end
mkfield("type", "Message Type", "c")
mkfield("length", "Message Length", "u16")
for _, d in ipairs(COMMON) do mkfield(d[1], d[2], d[3]) end
for _, m in pairs(MSG) do
  for _, d in ipairs(m[2]) do mkfield(d[1], d[2], d[3]) end
end
itch.fields = flist

local function fmt_ts(ns)
  local sec  = math.floor(ns / 1e9)
  local frac = math.floor(ns - sec * 1e9)
  return string.format("%02d:%02d:%02d.%09d",
    math.floor(sec / 3600), math.floor(sec / 60) % 60, sec % 60, frac)
end

local function add_field(t, buf, off, d)
  local key, label, kind = d[1], d[2], d[3]
  local len = d[4] or KLEN[kind]
  local r = buf(off, len)
  local f = F[key]
  local v, item

  if kind == "c" or kind == "s" then
    v = r:string()
    if kind == "s" then v = v:gsub("%s+$", "") end
    item = t:add(f, r, v)
    local dm = DESC[key]
    if dm and dm[v] then item:append_text(" (" .. dm[v] .. ")") end
  elseif kind == "u16" or kind == "u32" then
    v = r:uint()
    t:add(f, r, v)
  elseif kind == "u64" then
    v = r:uint64()
    t:add(f, r, v)
  elseif kind == "ts" then
    v = r:uint64()
    t:add(f, r, v):append_text(" (" .. fmt_ts(v:tonumber()) .. ")")
  elseif kind == "p4" then
    v = r:uint() / 1e4
    t:add(f, r, v):set_text(string.format("%s: %.4f", label, v))
  elseif kind == "p8" then
    v = r:uint64():tonumber() / 1e8
    t:add(f, r, v):set_text(string.format("%s: %.8f", label, v))
  end
  return len, v
end

local function dissect_msg(buf, off, mlen, tree, seq, lenrange)
  local mtype = buf(off, 1):string()
  local m = MSG[mtype]
  local name = m and m[1] or "Unknown"

  local t = tree:add(itch, buf(off, mlen),
    string.format("ITCH 5.0 %s ('%s'), Seq %s", name, mtype, tostring(seq)))
  t:add(F.length, lenrange, mlen)
  t:add(F.type, buf(off, 1), mtype):append_text(" (" .. name .. ")")
  if not m then return mtype .. ":" .. name end

  local p, stop, vals = off + 1, off + mlen, {}
  for _, list in ipairs({ COMMON, m[2] }) do
    for _, d in ipairs(list) do
      local len = d[4] or KLEN[d[3]]
      if p + len > stop then
        t:add_expert_info(PI_MALFORMED, PI_ERROR, "Message shorter than ITCH 5.0 layout")
        return mtype .. ":" .. name
      end
      local _, v = add_field(t, buf, p, d)
      vals[d[1]] = v
      p = p + len
    end
  end

  local s = mtype .. ":" .. name
  if vals.stock  then s = s .. " " .. vals.stock end
  if vals.side   then s = s .. " " .. vals.side end
  if vals.shares then s = s .. " " .. tostring(vals.shares) end
  if vals.price  then s = s .. string.format(" @ %.4f", vals.price) end
  if vals.order_ref then s = s .. " ref=" .. tostring(vals.order_ref) end
  return s
end

local function looks_like_mold(buf)
  local len = buf:len()
  if len < 20 then return false end
  local count = buf(18, 2):uint()
  if count == 0 or count == 0xFFFF then return len == 20 end
  local off = 20
  for _ = 1, count do
    if off + 2 > len then return false end
    off = off + 2 + buf(off, 2):uint()
  end
  return off == len
end

function mold.dissector(buf, pinfo, tree)
  if not looks_like_mold(buf) then return 0 end
  local len = buf:len()
  pinfo.cols.protocol = "ITCH 5.0"

  local mt = tree:add(mold, buf(0, 20))
  mt:add(mf.session, buf(0, 10), buf(0, 10):string())
  local seq = buf(10, 8):uint64()
  mt:add(mf.seq, buf(10, 8), seq)
  local count = buf(18, 2):uint()
  mt:add(mf.count, buf(18, 2), count)

  if count == 0 then
    pinfo.cols.info = "MoldUDP64 Heartbeat, next seq=" .. tostring(seq)
    return len
  elseif count == 0xFFFF then
    pinfo.cols.info = "MoldUDP64 End of Session"
    return len
  end

  local off, infos = 20, {}
  for i = 0, count - 1 do
    if off + 2 > len then break end
    local mlen = buf(off, 2):uint()
    if off + 2 + mlen > len then break end
    infos[#infos + 1] = dissect_msg(buf, off + 2, mlen, tree, seq + i, buf(off, 2))
    off = off + 2 + mlen
  end
  pinfo.cols.info = "seq=" .. tostring(seq) .. "  " .. table.concat(infos, " | ")
  return len
end

local udp = DissectorTable.get("udp.port")
udp:add(UDP_PORT, mold)
pcall(function() udp:add_for_decode_as(mold) end)

