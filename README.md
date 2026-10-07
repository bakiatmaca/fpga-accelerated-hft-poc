# Blog Post

## FPGA-Accelerated HFT: Tick-to-Trade Pipeline PoC Geliştirme Notları
<https://bakiatmaca.com/fpga-accelerated-hft-tick-to-trade-pipeline-poc-development-notes-438afe0f83ac>

## Fast Path
	Vivado project: fastpath/eventtriggerfpga 
	FPGA Board: Arty A7-100T XC7A100T (XC7A100TCSG324-1)

## Slow Path
	slowpath/generator
### order_sender : Signal Handler & Order Generator
	EF_POLL_USEC=-1 EF_USE_HUGE_PAGES=32 EF_INTERFACE_BLACKLIST=enp6s18 EF_INTERFACE_WHITELIST=enp1s0 taskset -c 4,5 onload --profile=latency -v ./order_sender -H 192.168.2.161 -P 34567 -R

### itch_replay : ITCH Market Data Feeder
	EF_POLL_USEC=-1 EF_USE_HUGE_PAGES=32 EF_INTERFACE_BLACKLIST=enp6s18 EF_INTERFACE_WHITELIST=enp1s0 taskset -c 6,7 onload --profile=latency -v ./itch_replay -f ../../nasdaq-data/01302019.NASDAQ_ITCH50.gz -d 192.168.2.28 -p 1234 -a -r 900

### Dummy OUCH server
	nc -lk 34567 | xxd

## Wireshark Dissector 
	dissector/
