-- Authored register-level NAND tests; no game/firmware bytes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_card_nand is generic(CE_PERIOD : positive := 1; SAVE_TYPE : positive := 9); end;
architecture test of tb_nds_card_nand is
 constant SAVE_SIZE : natural := 8388608 * (SAVE_TYPE-7);
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal ce, card7 : std_logic := '0';
 signal cycles : natural := 0;
 signal bus9, bus7 : proc_bus_gb_type := (Din=>(others=>'0'),Adr=>(others=>'0'),rnw=>'1',ena=>'0',acc=>ACCESS_32BIT,bEna=>(others=>'0'),rst=>'0');
 signal response9,response7 : std_logic_vector(31 downto 0);
 signal addr : std_logic_vector(19 downto 0);
 signal bank : std_logic_vector(3 downto 0);
 signal full_addr : std_logic_vector(23 downto 0);
 signal wd,rd,rd_delay : std_logic_vector(7 downto 0);
 signal we,active,ready,toggle,dma9,dma7,irq9,irq7,rom_ena : std_logic;
 signal writes,rom_reads : natural := 0;
 signal cache_sector : natural := 0;
 signal cache_delay : natural range 0 to 15 := 15;
 signal cache_valid : boolean := false;
 type ram_t is array(0 to 16777215) of std_logic_vector(7 downto 0);
 signal sample_low, sample_high : std_logic_vector(7 downto 0);
 function pattern(w : natural) return std_logic_vector is
 begin return std_logic_vector(to_unsigned(w*65537,32) xor x"A5C36987"); end;
begin
 clk <= not clk after 5 ns;
 process(clk) begin if rising_edge(clk) then cycles <= cycles+1; end if; end process;
 ce <= '1' when cycles mod CE_PERIOD = 0 else '0';
 full_addr <= bank & addr;
 ready <= '1' when cache_valid and cache_delay=0 else '0';
 process(clk)
  variable ram : ram_t := (others=>x"FF");
  variable a : natural;
 begin
  if rising_edge(clk) then
   a:=to_integer(unsigned(full_addr));
   rd_delay <= ram(a); rd <= rd_delay;
   sample_low<=ram(0); sample_high<=ram(16#100000#);
   if active='1' and (not cache_valid or cache_sector/=a/512) then
    cache_sector<=a/512; cache_delay<=15; cache_valid<=true;
   elsif cache_delay/=0 then cache_delay<=cache_delay-1; end if;
   if we='1' then
    assert ready='1' and cache_sector=a/512 report "write escaped cache ownership" severity failure;
    ram(a):=wd; writes<=writes+1;
   end if;
   if rom_ena='1' then rom_reads<=rom_reads+1; end if;
  end if;
 end process;
 dut: entity work.nds_card generic map(CARDSPEED_SHIFT=>2) port map(
  clk=>clk,ce=>ce,reset=>reset,card7=>card7,fw_boot=>'0',chipid=>x"08007FC2",
  nand_base=>x"06A00000",bus9=>bus9,bus7=>bus7,wired_out9=>response9,wired_done9=>open,
  wired_out7=>response7,wired_done7=>open,irq9_xfer=>irq9,irq7_xfer=>irq7,dma9_card=>dma9,dma7_card=>dma7,
  dbg_card=>open,card_ena=>rom_ena,card_addr=>open,card_din=>(others=>'0'),card_done=>'0',
  backup_addr=>addr,backup_bank=>bank,backup_write_data=>wd,backup_write_enable=>we,backup_read_data=>rd,
  backup_write_toggle=>toggle,backup_save_type=>std_logic_vector(to_unsigned(SAVE_TYPE,4)),backup_access_active=>active,backup_cache_ready=>ready);
 process
  procedure edge is begin
   loop wait until falling_edge(clk); exit when ce='1'; end loop;
  end;
  procedure put(a:natural; v:std_logic_vector(31 downto 0); other:boolean:=false) is
   variable b:proc_bus_gb_type;
  begin
   edge; b:=(Din=>v,Adr=>std_logic_vector(to_unsigned(a,28)),rnw=>'0',ena=>'1',acc=>ACCESS_32BIT,bEna=>"1111",rst=>'0');
   if (card7='1') xor other then bus7<=b; else bus9<=b; end if;
   wait until falling_edge(clk); bus9.ena<='0';bus7.ena<='0';bus9.rnw<='1';bus7.rnw<='1';
  end;
  procedure get(a:natural; variable v:out std_logic_vector(31 downto 0)) is
  begin
   edge;
   if card7='1' then bus7.Adr<=std_logic_vector(to_unsigned(a,28));bus7.rnw<='1';bus7.ena<='1';
   else bus9.Adr<=std_logic_vector(to_unsigned(a,28));bus9.rnw<='1';bus9.ena<='1';end if;
   wait for 1 ns; if card7='1' then v:=response7;else v:=response9;end if;
   wait until falling_edge(clk);bus9.ena<='0';bus7.ena<='0';
  end;
  procedure wait_word is variable v:std_logic_vector(31 downto 0);
  begin
   for i in 0 to 30000 loop get(16#1A4#,v);if v(23)='1' then return;end if;end loop;
   assert false report "NAND word timed out" severity failure;
  end;
  procedure idle is variable v:std_logic_vector(31 downto 0);
  begin
   for i in 0 to 30000 loop get(16#1A4#,v);if v(31)='0' then return;end if;end loop;
   assert false report "NAND command timed out" severity failure;
  end;
  procedure command(op:natural; a:natural; words:natural:=0; writing:boolean:=false) is
   variable cmd:std_logic_vector(63 downto 0):=(others=>'0');variable control:unsigned(31 downto 0):=x"80000000";
  begin
   idle;cmd(63 downto 56):=std_logic_vector(to_unsigned(op,8));cmd(55 downto 24):=std_logic_vector(to_unsigned(a,32));
   put(16#1A8#,cmd(39 downto 32)&cmd(47 downto 40)&cmd(55 downto 48)&cmd(63 downto 56));
   put(16#1AC#,cmd(7 downto 0)&cmd(15 downto 8)&cmd(23 downto 16)&cmd(31 downto 24));
   if words=1 then control(26 downto 24):="111";
   elsif words=128 then control(26 downto 24):="001";
   elsif words=512 then control(26 downto 24):="011";
   else assert words=0 severity failure;end if;
   if writing then control(30):='1';end if;
   put(16#1A4#,std_logic_vector(control));
   if words=0 then idle;end if;
  end;
  procedure status(variable v:out std_logic_vector(31 downto 0)) is
  begin command(16#D6#,0,1);wait_word;get(16#100010#,v);end;
  procedure settle_program is variable v:std_logic_vector(31 downto 0);
  begin
   for i in 0 to 10000 loop status(v);if v(5)='1' then return;end if;end loop;
   assert false report "NAND program stuck busy" severity failure;
  end;
  procedure read_check(a:natural; w:natural; expected:std_logic_vector(31 downto 0)) is variable v:std_logic_vector(31 downto 0);
  begin command(16#B7#,a+w*4,1);wait_word;get(16#100010#,v);
   assert v=expected report "NAND read mismatch address "&integer'image(a+w*4)&" got "&to_hstring(v)&" expected "&to_hstring(expected) severity failure;
  end;
  variable v:std_logic_vector(31 downto 0);variable count:natural;
 begin
  wait for 30 ns;wait until falling_edge(clk);reset<='0';wait for 6000 ns;
  put(16#1A0#,x"0000C000"); -- slot + transfer IRQ enable
  status(v);assert v=x"20202020" report "reset status" severity failure;
  command(16#94#,0,1);wait_word;get(16#100010#,v);assert v=x"9500F1EC" severity failure;
  command(16#B8#,0,1);wait_word;get(16#100010#,v);assert v=x"08007FC2" severity failure;
  -- Read-only/invalid windows and missing write-enable cannot write a save.
  command(16#B2#,16#06A00000#);count:=writes;
  command(16#81#,16#06A00000#,1,true);wait_word;put(16#100010#,x"12345678");command(16#82#,0);settle_program;
  assert writes=count report "write without WEL committed" severity failure;
  -- Four 512-byte transfers form a 2 KiB program, crossing the old 1 MiB limit.
  command(16#B2#,16#06AE0000#);command(16#85#,0);
  status(v);assert v=x"30303030" severity failure;
  for blockno in 0 to 3 loop
   command(16#81#,16#06AFFE00#,128,true);
   for w in 0 to 127 loop wait_word;put(16#100010#,pattern(blockno*128+w));end loop;
  end loop;
  assert writes=count report "staging wrote through before commit" severity failure;
  command(16#82#,0);status(v);assert v(5)='0' report "program never reported busy" severity failure;
  settle_program;assert writes=count+2048 report "program missing/duplicating bytes" severity failure;
  for w in 0 to 127 loop read_check(16#06AFFE00#,w,pattern(w));end loop;
  command(16#B2#,16#06B00000#);
  for w in 128 to 511 loop read_check(16#06AFFE00#,w,pattern(w));end loop;
  -- A streamed DMA-size read advances xferpos and crosses cache sectors.
  command(16#B7#,16#06B00000#,512);
  for w in 0 to 511 loop
   wait_word; get(16#100010#,v);
   if w < 384 then assert v=pattern(w+128) report "streamed read position/cache mismatch" severity failure;
   else assert v=x"FFFFFFFF" report "streamed read overrun" severity failure; end if;
  end loop;
  assert sample_low=x"FF" and sample_high=x"07" report "high address aliased low save memory" severity failure;
  -- Unaligned B7 read wraps inside 4 KiB, rather than crossing into next page.
  command(16#B2#,16#06AE0000#);read_check(16#06AFFFFE#,0,x"FFFFA5BC");
  -- Discard prevents staged bytes from leaking to disk.
  command(16#85#,0);command(16#81#,16#06AE0000#,1,true);wait_word;put(16#100010#,x"DEADBEEF");
  command(16#84#,0);command(16#82#,0);settle_program;assert writes=count+2048 severity failure;
  -- Read-only final block and its identity metadata.
  command(16#B2#,16#06A00000#+SAVE_SIZE-131072);read_check(16#06A00000#+SAVE_SIZE-2048,0,x"A19E00EC");
  command(16#85#,0);command(16#81#,16#06A00000#+SAVE_SIZE-2048,1,true);wait_word;put(16#100010#,x"DEADBEEF");
  command(16#82#,0);settle_program;assert writes=count+2048 report "read-only ID region written" severity failure;
  command(16#8B#,0);read_check(16#06A00000#,0,x"FFFFFFFF");
  -- ARM7 uses the same peripheral. Nonowner writes cannot change commands.
  card7<='1';put(16#1A8#,x"000000B2",true);status(v);assert v=x"20202020" severity failure;
  command(16#B2#,16#06B00000#);read_check(16#06B00000#,0,pattern(128));
  -- Short programs retain the unmodified staging bytes, not stale save bytes.
  command(16#B2#,16#06B00000#); command(16#85#,0);
  command(16#81#,16#06B01000#,1,true); wait_word; put(16#100010#,x"76543210");
  command(16#82#,0); settle_program;
  read_check(16#06B01000#,0,x"76543210"); read_check(16#06B01000#,1,pattern(1));
  count:=writes;
  command(16#85#,0); command(16#81#,16#06B01000#,1,true); wait_word; put(16#100010#,x"DEADBEEF");
  edge; reset<='1'; wait until falling_edge(clk); reset<='0'; wait for 6000 ns;
  put(16#1A0#,x"0000C000");
  status(v); assert v=x"20202020" report "reset did not clear NAND staging/WEL" severity failure;
  command(16#82#,0); settle_program; assert writes=count report "reset committed stale staging" severity failure;
  command(16#B2#,16#06B00000#); read_check(16#06B01000#,0,x"76543210");
  assert rom_reads=0 report "NAND save access escaped to ROM pager" severity failure;
  report "PASS: NAND page staging/commit, high addresses, cache stalls, ID/status, protection, discard and both CPU owners; CE period="&integer'image(CE_PERIOD);
  stop;wait;
 end process;
 process begin wait for 100 ms;assert false report "NAND bench watchdog" severity failure;end process;
end;
