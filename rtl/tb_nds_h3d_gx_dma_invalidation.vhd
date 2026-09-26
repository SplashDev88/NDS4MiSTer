-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exercise the actual production invalidation expression with the real
-- geometry readback owner. The runner injects the expression from console_top.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_h3d_gx_dma_invalidation is end;
architecture sim of tb_nds_h3d_gx_dma_invalidation is
 signal clk:std_logic:='0';signal reset:std_logic:='1';
 signal io_bus9:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"0000",'0');
 signal dma_gx_write_valid,gx_readback_geometry_write:std_logic:='0';
 signal cpu_read,busy,complete,fence_valid,request_valid:std_logic:='0';
 signal request_ready,response_valid:std_logic:='0';
 signal address:std_logic_vector(27 downto 0):=x"0000640";
 signal request_id,response_id,read_data:std_logic_vector(31 downto 0):=(others=>'0');
 signal cache_index:std_logic_vector(4 downto 0);
 signal cache_data:std_logic_vector(31 downto 0):=(others=>'0');
 signal fences:natural:=0;
begin
 clk<=not clk after 5 ns;
 -- PRODUCTION_INVALIDATION_EXPRESSION
 dut:entity work.nds_h3d_gx_readback_owner port map (
  clk=>clk,reset=>reset,service_ready=>'1',cpu_read=>cpu_read,address=>address,
  geometry_write=>gx_readback_geometry_write,selected=>open,busy=>busy,complete=>complete,read_data=>read_data,
  fence_valid=>fence_valid,request_valid=>request_valid,request_ready=>request_ready,request_id=>request_id,
  response_valid=>response_valid,response_id=>response_id,response_status=>x"00000000",
  cache_index=>cache_index,cache_data=>cache_data);
 process(clk) begin if rising_edge(clk) then
  cache_data<=x"ABCD00" & "000" & cache_index;
  if fence_valid='1' then fences<=fences+1;end if;
 end if;end process;
 process
  procedure tick is begin wait until rising_edge(clk);wait for 1 ns;end;
  procedure begin_read(a:natural) is begin
   address<=std_logic_vector(to_unsigned(a,28));cpu_read<='1';tick;cpu_read<='0';
  end;
  procedure write_io(a:natural;dma:boolean;accepted:boolean;dirty:std_logic) is begin
   io_bus9.Adr<=std_logic_vector(to_unsigned(a,28));io_bus9.rnw<='0';
   if dma then dma_gx_write_valid<='1';else dma_gx_write_valid<='0';end if;
   if accepted then io_bus9.ena<='1';else io_bus9.ena<='0';end if;
   wait for 1 ns;
   assert gx_readback_geometry_write=dirty report "DMA/CPU address filter wrong at " & integer'image(a) severity failure;
   tick;dma_gx_write_valid<='0';io_bus9.ena<='0';io_bus9.rnw<='1';
  end;
  procedure reply is begin
   assert request_valid='1' and complete='0' report "missing ordered query" severity failure;
   response_id<=request_id;request_ready<='1';tick;request_ready<='0';
   response_valid<='1';tick;response_valid<='0';tick;tick;
   assert complete='1' report "query reply failed" severity failure;tick;
  end;
  procedure cached(a:natural) is
   variable previous:natural;
  begin
   previous:=fences;begin_read(a);
   assert request_valid='0' report "2D write unnecessarily evicted matrix cache" severity failure;
   tick;tick;
   assert complete='1' and fences=previous report "cached matrix read waited for HPS" severity failure;
   assert read_data=std_logic_vector(unsigned'(x"ABCD0000")+5+(a-16#640#)/4)
    report "cached matrix value changed" severity failure;
   tick;
  end;
 begin
  tick;reset<='0';tick;
  begin_read(16#640#);
  -- A held 2D DMA write during an outstanding matrix query must not make
  -- that query's eventual response uncacheable either.
  write_io(16#14#,true,false,'0');reply;
  for i in 0 to 191 loop
   write_io(16#14#,true,true,'0');cached(16#640#+(i mod 16)*4);
  end loop;
  for a in 0 to 16#106C# loop
   if a<=16#6C# or (a>=16#240# and a<=16#249#) or a>=16#1000# then
    write_io(a,true,false,'0');
   end if;
  end loop;
  cached(16#67C#);
  write_io(16#14#,false,true,'0');cached(16#640#);
  -- Genuine geometry writes still invalidate at held-valid issue, before
  -- acceptance. Individual GX commands, FIFO, GXSTAT and power all count.
  for i in 0 to 4 loop
   case i is
    when 0=>write_io(16#400#,true,false,'1');
    when 1=>write_io(16#454#,true,false,'1');
    when 2=>write_io(16#600#,true,false,'1');
    when 3=>write_io(16#304#,true,false,'1');
    when others=>write_io(16#440#,false,true,'1');
   end case;
   begin_read(16#640#);reply;cached(16#67C#);
  end loop;
  assert fences=6 report "unexpected query count" severity failure;
  report "PASS: 192 HDMA scroll writes retain matrix cache; all genuine GX/power/status writes invalidate before acceptance" severity note;
  stop;wait;
 end process;
 process begin wait for 1 ms;assert false report "invalidation test timeout" severity failure;wait;end process;
end architecture;
