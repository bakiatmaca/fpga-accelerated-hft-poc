#!/usr/bin/env bash

parse_msg() {
  local buf="$1"   # 33 byte, hex-encoded (xxd -p) 
  # offset*2 = hex char index (each byte 2 hex char)
  local magic=${buf:0:2}
  local mtype=${buf:2:2}
  local ts=${buf:4:12}
  local oref=${buf:16:16}
  local side_hex=${buf:32:2}
  local shares=${buf:34:8}    
  local stock_hex=${buf:42:16}
  local price=${buf:58:8}

  #local side=$(printf "%b" "\x$side_hex")
  local side="${side_hex:+$(printf "%b" "\x$side_hex")}"  
  local shares_dec=$((16#$shares))
  local stock=$(echo -n "$stock_hex" | xxd -r -p | tr -c '[:print:]' '.')
  local price_dec=$((16#$price))
  
  # latency
  local ts_dec=$((16#$ts))           
  local now_ns=$(date +%s%N)         
  local ts_ns=$((ts_dec * 1000000))   # ms -> ns
  local diff_ns=$((now_ns - ts_ns))
  local diff_ms=$(( (diff_ns + 500000) / 1000000 ))
  
  printf "Magic:     0x%s\n" "$magic"
  printf "MsgType:   0x%s\n" "$mtype"
  printf "Timestamp: 0x%s (%d)\n" "$ts" "$((16#$ts))"
  printf "OrderRef:  0x%s (%d)\n" "$oref" "$((16#$oref))"
  printf "Side:      %s\n" "$side"
  printf "Shares:    0x%s (%d)\n" "$shares" "$shares_dec"
  printf "Stock:     %s\n" "$stock"
  printf "Price:     0x%s (%d)\n" "$price" "$price_dec"
  printf "Now(ms):   %d\n" "$((now_ns / 1000000))"
  printf "Latency:   %d.%03d ms (%d ns)\n" \
  "$((diff_ns / 1000000))" \
  "$(( (diff_ns % 1000000) / 1000 ))" \
  "$diff_ns"
  echo "-----------------------------"
}

nc -lv -u 1235 | while true; do
  # full 33 byte read, convert to hex
  hex=$(head -c 33 | xxd -p | tr -d '\n')
  [ -z "$hex" ] && break
  [ ${#hex} -lt 58 ] && break   # missing package
  parse_msg "$hex"
done
