ENTRY(primary)
stop_dma = 0x02052778;
sub_dst = 0x0204fe8c;
main_dst = 0x0204ff00;
copy_dma = 0x020523cc;
hblank_dma = 0x020528e8;
send_shape = 0x01ffa68c;
SECTIONS { .text 0x0200a328 : { *(.text) } }
