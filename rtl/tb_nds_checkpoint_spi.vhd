-- SPDX-License-Identifier: GPL-3.0-or-later
-- Product SPI byte drain, retained chipselect state and deferred lid sampling.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_spi is
 generic(LATENCY : positive := 1500; BAUD : natural := 0; PAUSE_OFFSET : natural := 17);
end;
architecture sim of tb_nds_checkpoint_spi is
 signal clk : std_logic := '0';
 signal reset : std_logic := '1';
 signal bus7 : proc_bus_gb_type := ((others=>'0'),x"00001C0",'1','0',ACCESS_32BIT,"0000",'0');
 signal hold,held,respond,req,wr,ack,release_cs,busy,irq,lid_irq : std_logic := '0';
 signal lid : std_logic := '1';
 signal q,data,memory_word : std_logic_vector(31 downto 0) := x"76543210";
 signal addr : unsigned(17 downto 2);
 signal lane : unsigned(1 downto 0);
 signal wdata : std_logic_vector(7 downto 0);
 signal done : std_logic;
 signal requests,returns,writes,irqs,lid_irqs,releases : natural := 0;
 signal rq : std_logic_vector(31 downto 0);
 signal raddr : unsigned(17 downto 2);
 signal rlane : unsigned(1 downto 0);
 signal rwdata : std_logic_vector(7 downto 0);
 signal rreq,rwr,rrelease,rirq,rlid,rdone : std_logic;
 signal compare : boolean := true;
begin
 clk<=not clk after 5 ns;
 dut:entity work.nds_nitro_spi generic map(EXPERIMENTAL_CHECKPOINT=>true)
 port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>q,wired_done7=>done,
  fw_addr=>addr,fw_req=>req,fw_wr=>wr,fw_wlane=>lane,fw_wdata=>wdata,
  fw_done=>ack,fw_data=>data,fw_busy=>busy,fw_release=>release_cs,
  irq_spi=>irq,irq_lid=>lid_irq,lid_closed=>lid,touch_active=>'1',touch_x=>x"84",touch_y=>x"63",mic_blow=>'1',
  checkpoint_stop=>hold,checkpoint_stopped=>held);
 reference_spi:entity work.nds_nitro_spi_reference
 port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>rq,wired_done7=>rdone,
  fw_addr=>raddr,fw_req=>rreq,fw_wr=>rwr,fw_wlane=>rlane,fw_wdata=>rwdata,
  fw_done=>ack,fw_data=>data,fw_busy=>busy,fw_release=>rrelease,
  irq_spi=>rirq,irq_lid=>rlid,lid_closed=>lid,touch_active=>'1',touch_x=>x"84",touch_y=>x"63",mic_blow=>'1');
 backing:process(clk)
  variable remaining : integer := -1;
  variable is_write : boolean;
  variable saved_lane : natural;
  variable saved_byte : std_logic_vector(7 downto 0);
 begin
  if rising_edge(clk) then
   ack<='0';
   if reset='1' then remaining:=-1;requests<=0;returns<=0;writes<=0;irqs<=0;lid_irqs<=0;releases<=0;
   else
    if irq='1' then irqs<=irqs+1;end if;
    if lid_irq='1' then lid_irqs<=lid_irqs+1;end if;
    if release_cs='1' then releases<=releases+1;end if;
    if req='1' or wr='1' then
     assert remaining=-1 and not(req='1' and wr='1') report "SPI backing ownership overlap" severity failure;
     assert addr=0 report "SPI command address changed across hold" severity failure;
     remaining:=LATENCY;is_write:=wr='1';saved_lane:=to_integer(lane);saved_byte:=wdata;requests<=requests+1;
    elsif remaining=0 and respond='1' then
     remaining:=-1;returns<=returns+1;ack<='1';
     if is_write then
      memory_word(saved_lane*8+7 downto saved_lane*8)<=saved_byte;writes<=writes+1;data<=x"DEADBEEF";
     else data<=memory_word;end if;
    elsif remaining>0 then remaining:=remaining-1;end if;
   end if;
  end if;
 end process;
 monitor:process
 begin
  wait until clk'event;wait for 1 ns;
  if compare then
   assert q=rq and done=rdone and addr=raddr and lane=rlane and wdata=rwdata and req=rreq and wr=rwr and
    release_cs=rrelease and irq=rirq and lid_irq=rlid
    report "SPI byte drain differs from baseline" severity failure;
  end if;
  if held='1' then
   assert hold='1' and reset='0' and bus7.ena='0' and q(7)='0' and requests=returns and
    req='0' and wr='0' and ack='0' and release_cs='0' and irq='0' and lid_irq='0'
    report "SPI acknowledged outstanding work" severity failure;
  end if;
 end process;
 stimulus:process
  variable got : std_logic_vector(7 downto 0);
  variable before,before_irq : natural;
  procedure step(n:positive:=1) is
  begin for k in 1 to n loop wait until rising_edge(clk);wait for 2 ns;end loop;end;
  procedure write_reg(d:std_logic_vector(31 downto 0);be:std_logic_vector(3 downto 0)) is
  begin
   bus7.Din<=d;bus7.bEna<=be;bus7.rnw<='0';bus7.ena<='1';wait for 1 ns;
   assert held='0' report "SPI bus admission falsely held" severity failure;
   step;bus7.rnw<='1';bus7.ena<='0';bus7.bEna<="0000";wait for 1 ns;
  end;
  procedure control(d:std_logic_vector(15 downto 0)) is
  begin write_reg(x"0000"&std_logic_vector(unsigned(d) or to_unsigned(BAUD,16)),"0011");end;
  procedure wait_held is
  begin
   for k in 1 to LATENCY+1000 loop exit when held='1';step;end loop;
   assert held='1' report "SPI byte/response did not drain" severity failure;
  end;
  procedure transfer(v:std_logic_vector(7 downto 0);variable result:out std_logic_vector(7 downto 0)) is
   variable old_irq : natural;
   variable saved : std_logic_vector(31 downto 0);
  begin
   hold<='0';old_irq:=irqs;write_reg(x"00"&v&x"0000","0100");
   for k in 1 to PAUSE_OFFSET loop step;end loop;
   hold<='1';wait_held;
   assert irqs=old_irq+1 report "SPI completion IRQ lost or duplicated" severity failure;
   result:=q(23 downto 16);saved:=q;step(23);
   assert q=saved and held='1' and irqs=old_irq+1 report "SPI byte state changed while held" severity failure;
  end;
  procedure address_zero is
   variable unused:std_logic_vector(7 downto 0);
  begin transfer(x"00",unused);transfer(x"00",unused);transfer(x"00",unused);end;
 begin
  respond<='1';step(4);reset<='0';step(3);
  -- Every byte is stopped at a different phase of the busy window.
  control(x"C900");transfer(x"06",got);control(x"0000");
  control(x"C900");transfer(x"0A",got);address_zero;
  before:=releases;transfer(x"5A",got);
  assert writes=1 and got=x"5A" and memory_word=x"7654325A" and releases=before
   report "SPI program/CS state lost across stop" severity failure;
  -- Cache dirty/busy is outside this local owner acknowledgement.
  busy<='1';step(4);assert held='1' report "SPI conflated local drain with cache durability" severity failure;
  control(x"0000");step(3);assert releases=before+1 report "SPI program release lost" severity failure;
  control(x"C900");transfer(x"05",got);transfer(x"00",got);assert got=x"03" severity failure;
  busy<='0';transfer(x"00",got);assert got=x"02" severity failure;control(x"0000");
  control(x"C900");transfer(x"03",got);address_zero;transfer(x"00",got);
  assert got=x"5A" report "SPI read command/lane lost across stop" severity failure;
  control(x"0000");control(x"C900");transfer(x"02",got);address_zero;
  control(x"C100");before:=releases;transfer(x"A6",got);
  assert got=x"A6" and writes=2 and releases=before+1 report "SPI final-byte release or echo lost" severity failure;
  control(x"0000");
  -- Withhold a real read, cancel/retry the hold, then deliver exactly once.
  control(x"C900");transfer(x"03",got);address_zero;respond<='0';
  hold<='0';before_irq:=irqs;write_reg(x"00000000","0100");hold<='1';step(LATENCY+700);
  assert held='0' and requests=returns+1 and irqs=before_irq report "SPI missing reply falsely completed" severity failure;
  hold<='0';step(13);assert requests=returns+1 report "SPI cancel lost pending reply" severity failure;
  hold<='1';respond<='1';wait_held;
  assert irqs=before_irq+1 and q(23 downto 16)=x"A6" report "SPI cancelled read did not recover" severity failure;
  control(x"0000");
  -- Preserve PM register index and touchscreen conversion between bytes.
  control(x"C800");transfer(x"00",got);transfer(x"3F",got);control(x"0000");
  control(x"C800");transfer(x"80",got);transfer(x"00",got);assert got=x"3F" report "PM register/index lost" severity failure;
  control(x"0000");control(x"CA00");transfer(x"D0",got);transfer(x"00",got);
  assert got=x"42" report "TSC high conversion lost" severity failure;
  transfer(x"00",got);assert got=x"00" report "TSC low conversion lost" severity failure;
  -- Held microphone command history matches the uninterrupted reference.
  for k in 1 to 12 loop transfer(x"E8",got);transfer(x"00",got);transfer(x"00",got);end loop;
  control(x"0000");wait_held;
  compare<=false;before:=lid_irqs;lid<='0';step(17);
  assert lid_irq='0' and lid_irqs=before and held='1' report "lid wake escaped held SPI" severity failure;
  hold<='0';step;assert lid_irq='1' report "deferred lid reopen lost" severity failure;
  step(4);assert lid_irqs=before+1 and lid_irq='0' report "lid reopen duplicated" severity failure;
  lid<='1';step(3);hold<='1';wait_held;
  lid<='0';step(3);lid<='1';step(3);hold<='0';step(3);
  assert lid_irqs=before+1 report "held lid transitions were replayed as an event log" severity failure;
  hold<='1';wait_held;reset<='1';step(3);assert held='0' report "SPI reset retained hold" severity failure;
  report "CHECKPOINT_SPI_PASS latency="&integer'image(LATENCY)&" baud="&integer'image(BAUD)&" phase="&integer'image(PAUSE_OFFSET);
  stop;wait;
 end process;
 process begin wait for 10 ms;assert false report "SPI checkpoint watchdog" severity failure;end process;
end;
