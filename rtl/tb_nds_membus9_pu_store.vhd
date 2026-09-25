-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored synthetic regression: denied CPU stores must not reach any target.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_membus9_pu_store is end;
architecture test of tb_nds_membus9_pu_store is
   signal clk: std_logic:='0'; signal reset: std_logic:='1';
   signal adr,din,dout: std_logic_vector(31 downto 0):=(others=>'0');
   signal ena,done,dma,code,cached,cpu_lock,denied: std_logic:='0';
   signal rnw: std_logic:='1'; signal acc: std_logic_vector(1 downto 0):=ACCESS_32BIT;
   signal op_ena,op_busy: std_logic:='0'; signal op: std_logic_vector(3 downto 0):=x"0";
   signal op_addr: std_logic_vector(31 downto 0):=(others=>'0');
   signal cache_debug: std_logic_vector(7 downto 0);
   signal mem_ena,mem_rnw,mem_pair,mem_lock,mem_done: std_logic;
   signal mem_addr: std_logic_vector(21 downto 2); signal mem_be: std_logic_vector(3 downto 0);
   signal mem_wdata,mem_rdata,mem_rdata_hi: std_logic_vector(31 downto 0):=(others=>'0');
   signal ia: unsigned(14 downto 2); signal da,dab: unsigned(13 downto 2);
   signal iw,dw,we,wr,ve,vr,pw,ow: std_logic;
   signal ibe,dbe: std_logic_vector(3 downto 0);signal iv,dv,ir,dr:std_logic_vector(31 downto 0):=(others=>'0');
   signal iob: proc_bus_gb_type;
   type ram is array(natural range <>) of std_logic_vector(31 downto 0);
   signal itcm: ram(0 to 8191):=(others=>x"FEED1234");
   signal dtcm: ram(0 to 4095):=(others=>x"FEED5678");
   signal main: ram(0 to 1023):=(others=>x"ABCD1234");
   signal writes: natural:=0;
begin
   clk<=not clk after 5 ns;
   dut : entity work.nds_membus9
      generic map (is_simu => '1')
      port map (
         clk => clk, reset => reset,
         itcm_ena => '1', itcm_load => '0', itcm_size => "00110",
         dtcm_ena => '1', dtcm_load => '0', dtcm_base => x"03000", dtcm_size => "00101",
         bus_cacheable_i => cached, bus_cacheable_d => cached, bus_wdenied_d => denied,
         cache_op_ena => op_ena, cache_op => op, cache_op_addr => op_addr, cache_op_busy => op_busy,
         dma_bus => dma, cpu_adr => adr, cpu_rnw => rnw, cpu_ena => ena, cpu_code => code, cpu_lock => cpu_lock,
         cpu_acc => acc, cpu_dout => dout, cpu_lowbits => adr(1 downto 0),
         cpu_lastread => x"BAD0BAD0", cpu_din => din, cpu_done => done,
         itcm_addr => ia, itcm_we => iw, itcm_be => ibe, itcm_writedata => iv,
         itcm_readdata => ir, dtcm_addr => da, dtcm_readdata => dr,
         dtcm_addr_b => dab, dtcm_we_b => dw, dtcm_be_b => dbe, dtcm_writedata_b => dv,
         brom_addr => open, brom_data => x"00000000",
         wsh_ena => we, wsh_rnw => wr, wsh_addr => open, wsh_be => open, wsh_din => open,
         wsh_dout => x"00000000", wsh_done => we, wsh_mapped => '1',
         vram_ena => ve, vram_rnw => vr, vram_addr => open, vram_be => open, vram_din => open,
         vram_dout => x"00000000", vram_done => ve,
         pal_we => pw, pal_addr => open, pal_din => open, pal_be => open,
         pal_readdata => x"00000000",
         oam_we => ow, oam_addr => open, oam_din => open, oam_be => open,
         mr_ena => mem_ena, mr_rnw => mem_rnw, mr_addr => mem_addr, mr_be => mem_be, mr_writedata => mem_wdata,
         mr_done => mem_done, mr_readdata => mem_rdata, mr_pair => mem_pair,
         mr_readdata_hi => mem_rdata_hi, mr_lock => mem_lock,
         dbg_cache => cache_debug, io_ce_next => '1', io_bus => iob, io_wired_out => x"00000000", io_wired_done => '1');
   process(clk)
     variable n: natural;
   begin
     if rising_edge(clk) then
       ir<=itcm(to_integer(ia)); dr<=dtcm(to_integer(da));
       if iw='1' then
         for lane in 0 to 3 loop if ibe(lane)='1' then itcm(to_integer(ia))(lane*8+7 downto lane*8)<=iv(lane*8+7 downto lane*8);end if;end loop;
       end if;
       if dw='1' then
         for lane in 0 to 3 loop if dbe(lane)='1' then dtcm(to_integer(dab))(lane*8+7 downto lane*8)<=dv(lane*8+7 downto lane*8);end if;end loop;
       end if;
       mem_done<='0';
       if mem_ena='1' then
         n:=to_integer(unsigned(mem_addr(11 downto 2)));
         mem_rdata<=main(n);mem_rdata_hi<=main((n+1) mod 1024);mem_done<='1';
         if mem_rnw='0' then
           for lane in 0 to 3 loop if mem_be(lane)='1' then main(n)(lane*8+7 downto lane*8)<=mem_wdata(lane*8+7 downto lane*8);end if;end loop;
         end if;
       end if;
       if iw='1' or dw='1' or (we='1' and wr='0') or (ve='1' and vr='0') or pw='1' or ow='1' or (iob.ena='1' and iob.rnw='0') or (mem_ena='1' and mem_rnw='0') then writes<=writes+1;end if;
     end if;
   end process;
   process
     variable before: natural;
     type addrs is array(natural range <>) of std_logic_vector(31 downto 0);
     constant destinations:addrs:=(x"00000000",x"03000000",x"02000000",x"03010000",x"04000000",x"05000000",x"06000000",x"07000000");
     procedure tick is begin wait until rising_edge(clk);wait for 1 ns;end;
     procedure drain is begin for n in 0 to 1000 loop exit when cache_debug(3 downto 0)=x"0" and op_busy='0';tick;end loop;tick;tick;end;
     procedure transfer(a,v:std_logic_vector(31 downto 0); rd,deny:std_logic; cacheable:std_logic:='0';is_dma:std_logic:='0';sz:std_logic_vector(1 downto 0):=ACCESS_32BIT) is
     begin
       wait until falling_edge(clk);adr<=a;dout<=v;rnw<=rd;denied<=deny;cached<=cacheable;dma<=is_dma;acc<=sz;ena<='1';
       tick;ena<='0';
       for n in 0 to 1000 loop exit when done='1';tick;end loop;
       assert done='1' report "request timeout " & to_hstring(a) severity failure;
       if rd='1' then assert din=v report "read mismatch " & to_hstring(a) & " got " & to_hstring(din) severity failure;end if;
       tick;
     end;
   begin
     tick;tick;reset<='0';tick;
     -- Word/halfword/byte denied accesses complete without any target writes.
     for dest in destinations'range loop
       for sz in 0 to 2 loop
         before:=writes;
         transfer(destinations(dest),x"00000000",'0','1',sz=>std_logic_vector(to_unsigned(sz,2)));drain;
         assert writes=before report "denied store leaked " & to_hstring(destinations(dest)) severity failure;
       end loop;
     end loop;
     transfer(x"00000000",x"FEED1234",'1','1');
     transfer(x"03000000",x"FEED5678",'1','1');
     -- Permitted stores still route, including DMA carrying stale CPU denial.
     for dest in destinations'range loop
       before:=writes;transfer(destinations(dest),x"12345678",'0','0');drain;
       assert writes=before+1 report "allowed store missing/duplicated " & to_hstring(destinations(dest)) severity failure;
     end loop;
     before:=writes;transfer(x"02000004",x"87654321",'0','1',is_dma=>'1');drain;
     assert writes=before+1 report "CPU denial blocked DMA" severity failure;
     transfer(x"02000004",x"87654321",'1','1');
     -- A denied cache-hit store must leave the existing cached value intact.
     transfer(x"02000040",x"ABCD1234",'1','0',cacheable=>'1');drain;
     transfer(x"02000040",x"AAAAAAAA",'0','0',cacheable=>'1');drain;
     before:=writes;transfer(x"02000040",x"00000000",'0','1',cacheable=>'1');drain;
     assert writes=before report "denied cached write reached memory" severity failure;
     transfer(x"02000040",x"AAAAAAAA",'1','1',cacheable=>'1');
     -- Consecutive acceptance: previous deferred DTCM store must still commit.
     wait until falling_edge(clk);adr<=x"03000000";dout<=x"ABCDEF01";rnw<='0';denied<='0';cached<='0';acc<=ACCESS_32BIT;ena<='1';
     tick;assert done='1' severity failure;denied<='1';dout<=x"00000000";
     tick;assert done='1' severity failure;ena<='0';tick;tick;
     transfer(x"03000000",x"ABCDEF01",'1','1');
     report "PASS: denied stores across 8 targets/3 sizes, DMA bypass, cache hits, reads and deferred DTCM ordering";
     stop;wait;
   end process;
end;
