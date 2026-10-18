-- SPDX-License-Identifier: GPL-3.0-or-later
-- Actual DMA + actual cartridge: stop ordering, queued trigger and exact data.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_card_dma is
 generic(ARM9 : boolean := true; LATENCY : positive := 17);
end;
architecture sim of tb_nds_checkpoint_card_dma is
 constant IDLE_BUS : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"1111",'0');
 signal card_owner : std_logic;
 signal clk : std_logic := '0';signal reset : std_logic := '1';
 signal regs,cpubus,dmabus,cardbus,bus9,bus7 : proc_bus_gb_type := IDLE_BUS;
 signal hold,dma_held,card_hold,card_held,running,owned,mbena,rnw,mbdone : std_logic := '0';
 signal mbaddr,mbdata,mbdin,cardq,cardq9,cardq7,carddbg : std_logic_vector(31 downto 0);
 signal irq : std_logic_vector(3 downto 0);
 signal trigger,trigger9,trigger7,req,ack : std_logic := '0';
 signal cardaddr : std_logic_vector(28 downto 2);signal carddata : std_logic_vector(31 downto 0);
 signal writes,reads,irqs : natural := 0;
 signal block_memory : boolean := false;
 signal memory_pending : boolean := false;
 function pattern(a : natural) return std_logic_vector is
 begin return std_logic_vector(to_unsigned(a,32) xor unsigned'(x"A55A0000"));end;
begin
 clk<=not clk after 5 ns;
 card_owner<='0' when ARM9 else '1';
 -- Same ordering as the console; the inactive other DMA is already stopped.
 card_hold<=hold and dma_held;
 cardbus<=dmabus when owned='1' else cpubus;
 bus9<=cardbus when ARM9 else IDLE_BUS;bus7<=IDLE_BUS when ARM9 else cardbus;
 cardq<=cardq9 when ARM9 else cardq7;trigger<=trigger9 when ARM9 else trigger7;
 card:entity work.nds_card generic map(CARDSPEED_SHIFT=>2,CARDPREFETCH=>4,EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,ce=>'1',reset=>reset,card7=>card_owner,chipid=>x"12345678",
  bus9=>bus9,wired_out9=>cardq9,wired_done9=>open,bus7=>bus7,wired_out7=>cardq7,wired_done7=>open,
  irq9_xfer=>open,irq7_xfer=>open,dma9_card=>trigger9,dma7_card=>trigger7,dbg_card=>carddbg,
  card_ena=>req,card_addr=>cardaddr,card_din=>carddata,card_done=>ack,
  checkpoint_stop=>card_hold,checkpoint_stopped=>card_held);
 nine:if ARM9 generate
  dut:entity work.nds_dma9 generic map(EXPERIMENTAL_CHECKPOINT=>true)
   port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
    checkpoint_stop=>hold,checkpoint_stopped=>dma_held,
    trig_vblank=>'0',trig_hblank=>'0',trig_card=>trigger,cpu_bus_idle=>'1',
    dma_on=>running,dma_bus_on=>owned,mb_ena=>mbena,mb_rnw=>rnw,mb_adr=>mbaddr,
    mb_acc=>open,mb_lowbits=>open,mb_dout=>mbdata,mb_din=>mbdin,mb_done=>mbdone,
    io_fast_ena=>dmabus.ena,io_fast_rnw=>dmabus.rnw,io_fast_adr=>dmabus.Adr,io_fast_acc=>dmabus.acc,
    io_fast_be=>dmabus.bEna,io_fast_dout=>dmabus.Din,io_fast_din=>cardq,
    vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,
    vram_fast_din=>open,vram_fast_dout=>(others=>'0'),vram_fast_done=>'0',
    vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',irq_dma=>irq);
 end generate;
 seven:if not ARM9 generate
  dmabus<=(mbdata,x"0"&mbaddr(23 downto 0),rnw,mbena and rnw,ACCESS_32BIT,"1111",'0');
  dut:entity work.nds_dma7 generic map(EXPERIMENTAL_CHECKPOINT=>true)
   port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
    checkpoint_stop=>hold,checkpoint_stopped=>dma_held,trig_vblank=>'0',trig_card=>trigger,cpu_bus_idle=>'1',
    dma_on=>running,dma_bus_on=>owned,mb_ena=>mbena,mb_rnw=>rnw,mb_adr=>mbaddr,
    mb_acc=>open,mb_lowbits=>open,mb_dout=>mbdata,mb_din=>mbdin,mb_done=>mbdone,irq_dma=>irq);
 end generate;
 memory:process(clk)
  variable delay,card_delay : integer := -1;
  variable saved_addr,saved_data : std_logic_vector(31 downto 0);
  variable saved_card : std_logic_vector(28 downto 2);
  variable reading : boolean;
 begin
  if rising_edge(clk) then
   ack<='0';mbdone<='0';
   if reset='1' then delay:=-1;card_delay:=-1;writes<=0;reads<=0;irqs<=0;
   else
    if irq(0)='1' then irqs<=irqs+1;end if;
    if req='1' then
     assert card_delay=-1 report "DMA/card overlapped backing read" severity failure;
     saved_card:=cardaddr;card_delay:=LATENCY;
    elsif card_delay=0 then
     carddata<=pattern(to_integer(unsigned(saved_card)));ack<='1';card_delay:=-1;
    elsif card_delay>0 then card_delay:=card_delay-1;end if;
    if dmabus.ena='1' and dmabus.rnw='1' then
     assert carddbg(27)='1' report "DMA read an unpublished cartridge word" severity failure;
     assert dmabus.Adr=x"0100010" report "DMA card source address changed" severity failure;
     reads<=reads+1;
    end if;
    if mbena='1' then
     assert delay=-1 report "DMA overlapping memory operation" severity failure;
     saved_addr:=mbaddr;saved_data:=mbdata;reading:=rnw='1';delay:=LATENCY;
     if reading then saved_data:=cardq;end if;
    elsif delay=0 and not block_memory then
     if reading then mbdin<=saved_data;
     else
      assert unsigned(saved_addr)=16#02008000#+writes*4 and saved_data=pattern(16#2000#+writes)
       report "DMA/card data or destination skipped/duplicated" severity failure;
      writes<=writes+1;
     end if;
     mbdone<='1';delay:=-1;
    elsif delay>0 and not block_memory then delay:=delay-1;end if;
   end if;
   memory_pending<=delay>=0;
  end if;
 end process;
 stimulus:process
  variable stopped_writes : natural;
  procedure step(n:positive:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
  procedure write_bus(signal b:out proc_bus_gb_type;a:natural;v:std_logic_vector(31 downto 0)) is
  begin
   b<=(v,std_logic_vector(to_unsigned(a,28)),'0','1',ACCESS_32BIT,"1111",'0');step;
   b.ena<='0';b.rnw<='1';step;
  end;
  procedure freeze is
  begin
   hold<='1';
   for k in 1 to LATENCY*8+500 loop exit when dma_held='1' and card_held='1';step;end loop;
   assert dma_held='1' and card_held='1' and not memory_pending report "DMA/card coordinated stop failed" severity failure;
   stopped_writes:=writes;step(89);
   assert writes=stopped_writes and dma_held='1' and card_held='1' report "DMA/card continued work after stop" severity failure;
  end;
 begin
  step(4);reset<='0';step(3);
  write_bus(regs,16#B0#,x"04100010");write_bus(regs,16#B4#,x"02008000");
  if ARM9 then write_bus(regs,16#B8#,x"EF000001");else write_bus(regs,16#B8#,x"E7000001");end if;
  freeze;
  -- Guest register writes already accepted during acquisition remain live.
  write_bus(cpubus,16#1A0#,x"00008000");write_bus(cpubus,16#1A8#,x"800000B7");
  write_bus(cpubus,16#1AC#,x"00000000");write_bus(cpubus,16#1A4#,x"81000000");
  step(20);assert writes=0 and carddbg(28)='1' and card_held='1' report "held card start not retained" severity failure;
  hold<='0';
  for phase in 0 to 3 loop
   for k in 1 to 30000 loop exit when writes>=phase*31+1 and mbena='1' and rnw='0';step;end loop;
   assert writes>=phase*31+1 and mbena='1' report "active DMA write fixture not reached" severity failure;
   if phase=1 then
    block_memory<=true;hold<='1';step(70);
    assert dma_held='0' and card_hold='0' and card_held='0' report "card stopped before active DMA drained" severity failure;
    hold<='0';step(7);hold<='1';block_memory<=false;
   end if;
   freeze;hold<='0';step;
  end loop;
  for k in 1 to 50000 loop exit when writes=128;step;end loop;step(20);
  assert writes=128 and reads=128 and irqs=128 and carddbg(28 downto 27)="00"
   report "DMA/card resume count or completion mismatch" severity failure;
  freeze;
  report "CHECKPOINT_CARD_DMA_PASS arm9="&boolean'image(ARM9)&" latency="&integer'image(LATENCY);
  stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "DMA/card checkpoint watchdog" severity failure;end process;
end;
