-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real DMA controllers, authored register traffic, delayed memory responses.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_checkpoint_dma is
  generic (ARM9 : boolean := true; LATENCY : positive := 1; CARD_TRIGGER : boolean := false);
end;
architecture sim of tb_nds_checkpoint_dma is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal regs : proc_bus_gb_type := ((others=>'0'),(others=>'0'),'1','0',ACCESS_32BIT,"0000",'0');
  signal request, stopped, running, owned, ena, rnw, done, trigger : std_logic := '0';
  signal cpu_idle : std_logic := '1';
  signal vblank, card : std_logic;
  signal freeze_reply : boolean := false;
  signal addr, dout, din : std_logic_vector(31 downto 0) := (others=>'0');
  signal irq : std_logic_vector(3 downto 0);
  signal writes, reads, interrupts : natural := 0;
  signal pending : boolean := false;
  constant COUNT : positive := 8;
  function contents(address : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin return address xor x"A55A1234";end;
begin
  clk <= not clk after 5 ns;
  vblank <= trigger when not CARD_TRIGGER else '0';
  card <= trigger when CARD_TRIGGER else '0';
  nine : if ARM9 generate
    dut : entity work.nds_dma9 generic map(EXPERIMENTAL_CHECKPOINT=>true)
      port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
        checkpoint_stop=>request,checkpoint_stopped=>stopped,
        trig_vblank=>vblank,trig_hblank=>'0',trig_card=>card,cpu_bus_idle=>cpu_idle,
        dma_on=>running,dma_bus_on=>owned,mb_ena=>ena,mb_rnw=>rnw,mb_adr=>addr,
        mb_acc=>open,mb_lowbits=>open,mb_dout=>dout,mb_din=>din,mb_done=>done,
        io_fast_ena=>open,io_fast_rnw=>open,io_fast_adr=>open,io_fast_acc=>open,
        io_fast_be=>open,io_fast_dout=>open,io_fast_din=>(others=>'0'),
        vram_fast_ena=>open,vram_fast_rnw=>open,vram_fast_addr=>open,vram_fast_be=>open,
        vram_fast_din=>open,vram_fast_dout=>(others=>'0'),vram_fast_done=>'0',
        vram_fast_wpost=>open,vram_fast_welig=>'0',vram_fast_wok=>'0',irq_dma=>irq);
  end generate;
  seven : if not ARM9 generate
    dut : entity work.nds_dma7 generic map(EXPERIMENTAL_CHECKPOINT=>true)
      port map(clk=>clk,reset=>reset,gb_bus=>regs,wired_out=>open,wired_done=>open,
        checkpoint_stop=>request,checkpoint_stopped=>stopped,
        trig_vblank=>vblank,trig_card=>card,cpu_bus_idle=>cpu_idle,
        dma_on=>running,dma_bus_on=>owned,mb_ena=>ena,mb_rnw=>rnw,mb_adr=>addr,
        mb_acc=>open,mb_lowbits=>open,mb_dout=>dout,mb_din=>din,mb_done=>done,irq_dma=>irq);
  end generate;
  memory : process(clk)
    variable active : boolean := false;
    variable remaining : natural := 0;
    variable a, value : std_logic_vector(31 downto 0);
    variable reading : boolean;
  begin
    if rising_edge(clk) then
      done<='0';
      if reset='1' then
        assert not active report "reset discarded accepted transaction" severity failure;
        writes<=0;reads<=0;interrupts<=0;
      else
        if irq(0)='1' then interrupts<=interrupts+1;end if;
        if stopped='1' then
          assert not active and ena='0' and owned='0' and running='0' and irq="0000"
            report "DMA falsely acknowledged a drained boundary" severity failure;
        end if;
        if active and not freeze_reply then
          if remaining=0 then
            if reading then
              din<=contents(a);reads<=reads+1;
            else
              assert unsigned(a)=16#02008000#+(writes mod COUNT)*4
                report "DMA destination lost continuation" severity failure;
              assert value=contents(std_logic_vector(to_unsigned(16#02001000#+writes*4,32)))
                report "DMA data skipped or duplicated across stop" severity failure;
              writes<=writes+1;
            end if;
            done<='1';active:=false;
          else remaining:=remaining-1;end if;
        end if;
        if ena='1' then
          assert not active and owned='1' report "overlapping/unowned DMA request" severity failure;
          active:=true;remaining:=LATENCY-1;a:=addr;value:=dout;reading:=rnw='1';
        end if;
      end if;
      pending<=active;
    end if;
  end process;
  process
    procedure clocks(n : natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure reg(a : natural; value : std_logic_vector(31 downto 0)) is
    begin
      regs.Adr<=std_logic_vector(to_unsigned(a,28));regs.Din<=value;
      regs.ena<='1';regs.rnw<='0';regs.bEna<="1111";clocks(1);
      regs.ena<='0';regs.rnw<='1';clocks(1);
    end;
    procedure setup(repeated : boolean := false) is
      variable control : unsigned(31 downto 0);
    begin
      reset<='1';request<='0';trigger<='0';cpu_idle<='1';clocks(4);reset<='0';clocks(3);
      reg(16#B0#,x"02001000");reg(16#B4#,x"02008000");
      -- Increment source, reload destination for each repeating VBlank batch.
      control:=unsigned'(x"C4600000") or to_unsigned(COUNT,32);
      if repeated then
        if ARM9 then
          if CARD_TRIGGER then control:=control or x"2A000000";else control:=control or x"0A000000";end if;
        else
          if CARD_TRIGGER then control:=control or x"22000000";else control:=control or x"12000000";end if;
        end if;
      end if;
      reg(16#B8#,std_logic_vector(control));
    end;
    procedure await_stopped is
    begin
      for i in 1 to 10000 loop clocks(1);exit when stopped='1';end loop;
      assert stopped='1' report "DMA stop never drained" severity failure;
    end;
    procedure await_writes(n : natural) is
    begin
      for i in 1 to 10000 loop clocks(1);exit when writes>=n;end loop;
      assert writes=n report "DMA lost queued work after release" severity failure;
    end;
  begin
    -- Abort an ungranted acquisition, preserving the channel's pending bit.
    setup;cpu_idle<='0';
    for i in 1 to 20 loop clocks(1);exit when running='1';end loop;
    assert running='1' and writes=0 and reads=0 report "grant fixture failed" severity failure;
    request<='1';await_stopped;clocks(12);
    assert writes=0 and reads=0 report "ungranted checkpoint issued DMA" severity failure;
    request<='0';cpu_idle<='1';await_writes(COUNT);clocks(10);
    assert interrupts=1 report "grant cancellation lost completion IRQ" severity failure;

    -- A trigger received during a stopped interval, and a later trigger while
    -- the first transfer drains, must both survive.
    setup(true);request<='1';await_stopped;
    trigger<='1';clocks(1);trigger<='0';clocks(12);
    assert writes=0 and reads=0 report "stopped DMA consumed a trigger" severity failure;
    request<='0';await_writes(2);request<='1';
    trigger<='1';clocks(1);trigger<='0';await_stopped;clocks(12);
    assert writes=COUNT and interrupts=1 report "active drain lost/duplicated first transfer" severity failure;
    request<='0';await_writes(COUNT*2);clocks(12);
    assert interrupts=2 report "pending repeat trigger was lost" severity failure;

    -- A new VBlank on LATCH is a second request, even when stop arrives on
    -- that same edge. GRANT is held so the collision is deterministic.
    setup(true);cpu_idle<='0';trigger<='1';clocks(1);trigger<='0';
    for i in 1 to 20 loop clocks(1);exit when running='1';end loop;
    cpu_idle<='1';clocks(1);request<='1';trigger<='1';clocks(1);trigger<='0';
    await_stopped;
    assert writes=COUNT and interrupts=1 report "LATCH collision damaged first batch" severity failure;
    request<='0';await_writes(COUNT*2);clocks(12);
    assert interrupts=2 report "LATCH collision lost pending repeat" severity failure;

    -- No acknowledgement may invent a completion when memory is unavailable.
    setup;freeze_reply<=true;
    for i in 1 to 100 loop clocks(1);exit when pending;end loop;
    assert pending report "stall fixture failed" severity failure;
    request<='1';clocks(50);
    assert stopped='0' and running='1' and pending report "missing response was discarded" severity failure;
    request<='0';freeze_reply<=false;await_writes(COUNT);clocks(12);
    assert interrupts=1 report "cancelled drain did not resume" severity failure;
    report "PASS: DMA stop/grant/repeat/late-response, ARM9=" & boolean'image(ARM9) &
      " latency=" & integer'image(LATENCY) & " card=" & boolean'image(CARD_TRIGGER);
    stop;wait;
  end process;
end;
