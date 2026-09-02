library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_h3d_dma9_gx is
end entity;

architecture sim of tb_nds_h3d_dma9_gx is
   signal clk, reset : std_logic := '0';
   signal regs_bus : proc_bus_gb_type :=
      (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
       ena => '0', acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal wired_out : std_logic_vector(31 downto 0);
   signal wired_done : std_logic;

   signal gx_supported, trig_gx, trig_hblank : std_logic := '0';
   signal check_dma_preemption : std_logic := '0';
   signal check_unit_preemption : std_logic := '0';
   signal gx_write_ready : std_logic := '1';
   signal gx_write_valid : std_logic;
   signal dma_on, dma_bus_on : std_logic;
   signal cpu_bus_idle_s : std_logic := '1';

   signal mb_ena, mb_rnw, mb_done : std_logic := '0';
   signal mb_adr, mb_dout, mb_din : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal mb_acc, mb_lowbits : std_logic_vector(1 downto 0);

   signal io_ena, io_rnw : std_logic;
   signal io_adr : std_logic_vector(27 downto 0);
   signal io_acc : std_logic_vector(1 downto 0);
   signal io_be : std_logic_vector(3 downto 0);
   signal io_dout : std_logic_vector(31 downto 0);

   signal vr_ena, vr_rnw, vr_wpost, vr_write_valid : std_logic;
   signal vr_addr : unsigned(23 downto 2);
   signal vr_be : std_logic_vector(3 downto 0);
   signal vr_din : std_logic_vector(31 downto 0);
   signal vr_welig, vr_wok : std_logic := '0';
   signal irq_dma : std_logic_vector(3 downto 0);

   signal mem_reads, mem_writes : natural := 0;
   signal gx_writes : natural := 0;
   signal dma0_writes : natural := 0;
   signal dma1_writes : natural := 0;
   signal bg1_hofs_writes : natural := 0;
   signal vr_writes : natural := 0;
   signal irq_count : natural := 0;

   function memory_data(addr : std_logic_vector(31 downto 0))
      return std_logic_vector is
   begin
      return addr xor x"A5A50000";
   end function;
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_dma9
      port map
      (
         clk => clk, reset => reset,
         gb_bus => regs_bus, wired_out => wired_out, wired_done => wired_done,
         trig_vblank => '0', trig_hblank => trig_hblank, trig_card => '0',
         gx_supported => gx_supported, trig_gx => trig_gx,
         gx_write_ready => gx_write_ready, gx_write_valid => gx_write_valid,
         cpu_bus_idle => cpu_bus_idle_s, dma_on => dma_on, dma_bus_on => dma_bus_on,
         mb_ena => mb_ena, mb_rnw => mb_rnw, mb_adr => mb_adr,
         mb_acc => mb_acc, mb_lowbits => mb_lowbits, mb_dout => mb_dout,
         mb_din => mb_din, mb_done => mb_done,
         io_fast_ena => io_ena, io_fast_rnw => io_rnw,
         io_fast_adr => io_adr, io_fast_acc => io_acc,
         io_fast_be => io_be, io_fast_dout => io_dout,
         io_fast_din => x"00000000",
         vram_fast_ena => vr_ena, vram_fast_rnw => vr_rnw,
         vram_fast_addr => vr_addr, vram_fast_be => vr_be,
         vram_fast_din => vr_din, vram_fast_dout => x"00000000",
         vram_fast_done => '0', vram_fast_wpost => vr_wpost,
         vram_fast_welig => vr_welig, vram_fast_wok => vr_wok,
         vram_write_valid => vr_write_valid,
         irq_dma => irq_dma
      );

   -- Delayed memory responder: every accepted request receives exactly one
   -- completion after 0..3 extra clocks. This gives both halves of the DMA
   -- handshake real stalls while retaining the request payload.
   memory_model : process (clk)
      variable pending : boolean := false;
      variable wait_left : natural range 0 to 3 := 0;
      variable pending_rnw : std_logic := '1';
      variable pending_addr, pending_data : std_logic_vector(31 downto 0) :=
         (others => '0');
      variable last_read : std_logic_vector(31 downto 0) := (others => '0');
   begin
      if rising_edge(clk) then
         mb_done <= '0';
         if (reset = '1') then
            pending := false;
            wait_left := 0;
            mem_reads <= 0;
            mem_writes <= 0;
            dma1_writes <= 0;
            mb_din <= (others => '0');
            last_read := (others => '0');
         elsif pending then
            if (wait_left = 0) then
               if (pending_rnw = '1') then
                  last_read := memory_data(pending_addr);
                  mb_din <= last_read;
               else
                  assert pending_data = last_read
                     report "DMA memory write did not retain its source read"
                     severity failure;
               end if;
               mb_done <= '1';
               pending := false;
            else
               wait_left := wait_left - 1;
            end if;
         elsif (mb_ena = '1') then
            pending := true;
            pending_rnw := mb_rnw;
            pending_addr := mb_adr;
            pending_data := mb_dout;
            wait_left := to_integer(unsigned(mb_adr(3 downto 2)));
            if (mb_rnw = '1') then
               mem_reads <= mem_reads + 1;
            else
               mem_writes <= mem_writes + 1;
               if (unsigned(mb_adr) >= unsigned'(x"02030000") and
                   unsigned(mb_adr) < unsigned'(x"02030010")) then
                  if (check_unit_preemption = '1' and dma1_writes = 1) then
                     assert dma0_writes = 1
                        report "DMA0 HBlank did not preempt DMA1 before its second unit"
                        severity failure;
                  end if;
                  dma1_writes <= dma1_writes + 1;
               end if;
            end if;
         end if;
      end if;
   end process;

   -- Accepted GXFIFO writes must be contiguous, 32-bit, fixed-destination,
   -- and data-identical to the corresponding source word. The assertion on
   -- ready proves a stalled word is not presented to the peripheral at all.
   gx_monitor : process (clk)
      variable expected_addr : std_logic_vector(31 downto 0);
      variable expected_data : std_logic_vector(31 downto 0);
      variable stalled : boolean := false;
      variable stalled_addr : std_logic_vector(27 downto 0) := (others => '0');
      variable stalled_data : std_logic_vector(31 downto 0) := (others => '0');
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            gx_writes <= 0;
            dma0_writes <= 0;
            bg1_hofs_writes <= 0;
            vr_writes <= 0;
            irq_count <= 0;
            stalled := false;
         else
            assert not (gx_write_ready = '0' and io_ena = '1' and
                        io_rnw = '0' and io_adr >= x"0000400" and
                        io_adr < x"0000440")
               report "GXFIFO request escaped while transport was full"
               severity failure;
            if (stalled) then
               assert gx_write_valid = '1' and io_adr = stalled_addr and
                      io_dout = stalled_data
                  report "stalled GXFIFO valid or payload was not held"
                  severity failure;
            end if;
            if (gx_write_valid = '1' and gx_write_ready = '0') then
               if (not stalled) then
                  stalled_addr := io_adr;
                  stalled_data := io_dout;
               end if;
               stalled := true;
            elsif (gx_write_valid = '1' and gx_write_ready = '1') then
               stalled := false;
            end if;
            if (io_ena = '1' and io_rnw = '0' and
                io_adr >= x"0000400" and io_adr < x"0000440") then
               if (check_dma_preemption = '1' and gx_writes = 112) then
                  assert dma0_writes = 1
                     report "DMA0 HBlank did not retire before GX word 113"
                     severity failure;
               end if;
               expected_addr := std_logic_vector(
                  unsigned'(x"02000000") + to_unsigned(gx_writes * 4, 32));
               assert io_adr = x"0000400"
                  report "GXFIFO DMA destination was not fixed" severity failure;
               assert io_acc = ACCESS_32BIT and io_be = "1111"
                  report "GXFIFO DMA did not preserve 32-bit access width"
                  severity failure;
               assert io_dout = memory_data(expected_addr)
                  report "GXFIFO DMA lost, repeated, or reordered a source word"
                  severity failure;
               gx_writes <= gx_writes + 1;
            elsif (io_ena = '1' and io_rnw = '0' and io_adr = x"0000000") then
               assert io_dout = memory_data(x"02010000")
                  report "DMA0 HBlank payload mismatch" severity failure;
               dma0_writes <= dma0_writes + 1;
            elsif (io_ena = '1' and io_rnw = '0' and io_adr = x"0000014") then
               expected_addr := std_logic_vector(
                  unsigned'(x"0231295C") + to_unsigned(bg1_hofs_writes * 2, 32));
               expected_data := memory_data(expected_addr);
               assert io_acc = ACCESS_16BIT and io_be = "0011"
                  report "NSMB BG1 HBlank DMA lost its 16-bit BG1HOFS lane"
                  severity failure;
               assert io_dout(15 downto 0) = expected_data(15 downto 0)
                  report "NSMB BG1 HBlank DMA skipped or repeated a scroll-table entry"
                  severity failure;
               bg1_hofs_writes <= bg1_hofs_writes + 1;
            end if;
            if (vr_ena = '1' and vr_rnw = '0') then
               assert vr_welig = '0' or vr_wok = '1'
                  report "VRAM DMA retired without local write credit"
                  severity failure;
               vr_writes <= vr_writes + 1;
            end if;
            for i in 0 to 3 loop
               if (irq_dma(i) = '1') then irq_count <= irq_count + 1; end if;
            end loop;
         end if;
      end if;
   end process;

   stimulus : process
      procedure write_reg(
         constant addr : std_logic_vector(27 downto 0);
         constant data : std_logic_vector(31 downto 0);
         constant be   : std_logic_vector(3 downto 0) := "1111") is
      begin
         wait until falling_edge(clk);
         regs_bus.Adr <= addr;
         regs_bus.Din <= data;
         regs_bus.rnw <= '0';
         regs_bus.ena <= '1';
         regs_bus.acc <= ACCESS_32BIT;
         regs_bus.bEna <= be;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         regs_bus.ena <= '0';
         regs_bus.rnw <= '1';
         regs_bus.bEna <= "0000";
      end procedure;

      procedure wait_for_irq(constant target : natural) is
      begin
         for i in 0 to 10000 loop
            wait until falling_edge(clk);
            exit when irq_count >= target;
            assert i < 10000 report "DMA completion IRQ timeout" severity failure;
         end loop;
      end procedure;

      variable read_base, write_base, irq_base : natural;
      variable cycles : natural;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      -- NSMB's castle scene streams one 16-bit BG1HOFS value per visible
      -- HBlank from an incrementing table. If the previous HBlank request was
      -- delayed at the bus grant, the next pulse can coincide with LATCH. That
      -- new event must remain pending; losing it shifts every later parallax
      -- band and produces the observed jumping clouds and hills.
      cpu_bus_idle_s <= '1';
      trig_hblank <= '0';
      write_reg(x"00000BC", x"0231295C");
      write_reg(x"00000C0", x"04000014");
      write_reg(x"00000C4", x"92600001");
      trig_hblank <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      trig_hblank <= '0';
      cpu_bus_idle_s <= '0';
      cycles := 0;
      while dma_on = '0' loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 100 report "NSMB BG1 HBlank DMA did not request the bus" severity failure;
      end loop;
      for i in 0 to 31 loop wait until rising_edge(clk); end loop;
      wait until falling_edge(clk);
      cpu_bus_idle_s <= '1';
      wait until rising_edge(clk); -- GRANT accepts; LATCH is now current
      wait until falling_edge(clk);
      assert dma_bus_on = '1'
         report "NSMB BG1 HBlank fixture did not reach delayed LATCH" severity failure;
      trig_hblank <= '1';
      wait until rising_edge(clk); -- the next visible-line HBlank hits LATCH
      wait until falling_edge(clk);
      trig_hblank <= '0';
      cycles := 0;
      while bg1_hofs_writes < 2 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 300
            report "HBlank coincident with LATCH was lost; BG1 parallax stream shifted"
            severity failure;
      end loop;
      assert bg1_hofs_writes = 2
         report "NSMB BG1 HBlank DMA duplicated an event" severity failure;
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      -- A higher-priority channel must interrupt an ordinary lower-priority
      -- DMA between transfer units, not merely at the special 112-word GX
      -- service boundary. This is the ordering required when a BG HBlank fill
      -- becomes pending during a longer channel-1 transfer.
      check_unit_preemption <= '1';
      trig_hblank <= '0';
      write_reg(x"00000B0", x"02010000");
      write_reg(x"00000B4", x"04000000");
      write_reg(x"00000B8", x"D4000001");
      write_reg(x"00000BC", x"02020000");
      write_reg(x"00000C0", x"02030000");
      write_reg(x"00000C4", x"C4000004");
      cycles := 0;
      while dma1_writes < 1 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 1000 report "DMA1 preemption fixture did not start" severity failure;
      end loop;
      trig_hblank <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      trig_hblank <= '0';
      cycles := 0;
      while dma0_writes < 1 or dma1_writes < 4 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 2000 report "DMA0/DMA1 unit preemption timeout" severity failure;
      end loop;
      assert dma0_writes = 1 and dma1_writes = 4
         report "ordinary DMA preemption duplicated or lost a transfer"
         severity failure;
      check_unit_preemption <= '0';
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      -- A higher-priority HBlank request arriving during a GX FIFO transfer
      -- must run at the 112-word service boundary. DMA3 retains the CPU pause;
      -- DMA0 must retire before GX word 113.
      gx_supported <= '1';
      check_dma_preemption <= '1';
      trig_gx <= '0';
      trig_hblank <= '0';
      gx_write_ready <= '1';
      write_reg(x"00000B0", x"02010000");
      write_reg(x"00000B4", x"04000000");
      write_reg(x"00000B8", x"D4000001");
      write_reg(x"00000D4", x"02000000");
      write_reg(x"00000D8", x"04000400");
      write_reg(x"00000DC", x"FC400076");
      trig_gx <= '1';
      cycles := 0;
      while gx_writes < 108 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 10000 report "GX preemption fixture timeout" severity failure;
      end loop;
      trig_hblank <= '1';
      wait until rising_edge(clk);
      wait until falling_edge(clk);
      trig_hblank <= '0';
      assert gx_writes < 112
         report "DMA0 HBlank trigger was not armed before GX word 112"
         severity failure;
      cycles := 0;
      while gx_writes < 118 or dma0_writes < 1 loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert dma_on = '1'
            report "GX slice arbitration released the CPU" severity failure;
         assert cycles < 10000 report "GX/DMA0 preemption completion timeout" severity failure;
      end loop;
      assert dma0_writes = 1
         report "DMA0 HBlank did not retire exactly once" severity failure;
      check_dma_preemption <= '0';
      trig_gx <= '0';
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      -- Even with the normalized FIFO continuously below half, a long GX DMA
      -- must expose the architectural CPU arbitration window after word 112.
      -- Without it, back-to-back slices can starve NSMB's VBlank handler and
      -- its line-0 BG1HOFS initialization until scanout has already started.
      gx_supported <= '1';
      trig_gx <= '0';
      gx_write_ready <= '1';
      write_reg(x"00000D4", x"02000000");
      write_reg(x"00000D8", x"04000400");
      irq_base := irq_count;
      write_reg(x"00000DC", x"FC400076");
      trig_gx <= '1';
      cycles := 0;
      while dma_on = '0' loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 100 report "GX CPU-yield fixture did not start" severity failure;
      end loop;
      loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         exit when dma_on = '0';
         assert cycles < 10000 report "GX inter-slice CPU-yield timeout" severity failure;
      end loop;
      assert gx_writes = 112 and irq_count = irq_base
         report "GX DMA did not yield the CPU at the 112-word boundary"
         severity failure;
      wait_for_irq(irq_base + 1);
      assert gx_writes = 118
         report "GX DMA CPU yield duplicated or lost its continuation"
         severity failure;
      trig_gx <= '0';
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      -- Unrelated immediate DMA behavior remains intact.
      write_reg(x"00000B0", x"02001000");
      write_reg(x"00000B4", x"02002000");
      read_base := mem_reads;
      write_base := mem_writes;
      irq_base := irq_count;
      write_reg(x"00000B8", x"C4000003");
      wait_for_irq(irq_base + 1);
      assert mem_reads = read_base + 3 and mem_writes = write_base + 3
         report "non-GX immediate DMA regressed" severity failure;

      -- gx_supported defaults fail-safe: arming timing 7 cannot issue a read
      -- merely because the trigger input is high.
      trig_gx <= '1';
      gx_supported <= '0';
      write_reg(x"00000D4", x"02000000");
      write_reg(x"00000D8", x"04000400");
      read_base := mem_reads;
      write_reg(x"00000DC", x"FC400001");
      for i in 0 to 15 loop wait until rising_edge(clk); end loop;
      assert mem_reads = read_base and gx_writes = 0 and dma_on = '0'
         report "unsupported GX mode did not preserve the pre-3D behavior"
         severity failure;
      write_reg(x"00000DC", x"7C400001"); -- disable the parked channel

      -- Arm a captured NSMB-sized 118-word batch while GX is not requesting.
      gx_supported <= '1';
      trig_gx <= '0';
      write_reg(x"00000D4", x"02000000");
      write_reg(x"00000D8", x"04000400");
      read_base := mem_reads;
      irq_base := irq_count;
      write_reg(x"00000DC", x"FC400076");
      for i in 0 to 7 loop wait until rising_edge(clk); end loop;
      assert mem_reads = read_base and dma_on = '0'
         report "GX DMA ran before a below-half request" severity failure;

      trig_gx <= '1';
      cycles := 0;
      while gx_writes < 112 loop
         wait until falling_edge(clk);
         -- Deterministic transport gaps exercise exact-word backpressure.
         if ((cycles mod 7) = 1 or (cycles mod 7) = 2) then
            gx_write_ready <= '0';
         else
            gx_write_ready <= '1';
         end if;
         if (gx_writes >= 110) then trig_gx <= '0'; end if;
         cycles := cycles + 1;
         assert cycles < 10000 report "first GX DMA slice timeout" severity failure;
      end loop;
      gx_write_ready <= '1';

      -- A low request at the 112-word boundary releases the CPU without an
      -- IRQ or enable clear, and preserves the six-word continuation.
      for i in 0 to 8 loop
         wait until falling_edge(clk);
         exit when dma_on = '0';
      end loop;
      assert dma_on = '0' and gx_writes = 112 and irq_count = irq_base
         report "GX DMA completed prematurely at the 112-word boundary"
         severity failure;
      regs_bus.Adr <= x"00000DC";
      wait for 1 ns;
      assert wired_done = '1' and wired_out(31) = '1'
         report "GX DMA enable did not remain armed across a partial batch"
         severity failure;

      -- Software-visible registers may change while the DMA is paused. The
      -- in-progress transfer must retain its already-latched source, fixed
      -- destination, and total remaining count rather than jumping to them.
      write_reg(x"00000D4", x"022A0E3C");
      write_reg(x"00000D8", x"04000420");
      write_reg(x"00000DC", x"00000003", "0011");

      trig_gx <= '1';
      gx_write_ready <= '1';
      wait_for_irq(irq_base + 1);
      for i in 0 to 8 loop
         wait until falling_edge(clk);
         exit when dma_on = '0';
      end loop;
      assert gx_writes = 118 and mem_reads = read_base + 118
         report "GX DMA did not drain the full preserved 118-word count"
         severity failure;
      regs_bus.Adr <= x"00000DC";
      wait for 1 ns;
      assert wired_out(31) = '0'
         report "GX DMA enable did not clear at total completion"
         severity failure;
      regs_bus.Adr <= x"00000D4";
      wait for 1 ns;
      assert wired_out = x"022A0E3C"
         report "SAD readback did not retain the CPU register update"
         severity failure;
      regs_bus.Adr <= x"00000D8";
      wait for 1 ns;
      assert wired_out = x"04000420"
         report "DAD readback did not retain the CPU register update"
         severity failure;

      assert vr_ena = '0'
         report "GX DMA unexpectedly touched the VRAM fast lane"
         severity failure;

      -- A repeating mode-7 channel consumes one below-half request. Holding
      -- the constant-empty approximation high cannot make it spin forever;
      -- a fresh low-to-high request starts the next programmed count.
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      gx_supported <= '1';
      trig_gx <= '0';
      gx_write_ready <= '1';
      write_reg(x"00000D4", x"02000000");
      write_reg(x"00000D8", x"04000400");
      write_reg(x"00000DC", x"FE400002");
      trig_gx <= '1';
      wait_for_irq(1);
      for i in 0 to 30 loop wait until falling_edge(clk); end loop;
      assert gx_writes = 2 and irq_count = 1 and dma_on = '0'
         report "constant GX level restarted a repeat channel without a new request"
         severity failure;
      regs_bus.Adr <= x"00000DC";
      wait for 1 ns;
      assert wired_out(31) = '1'
         report "repeat GX DMA did not remain enabled" severity failure;
      trig_gx <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      trig_gx <= '1';
      wait_for_irq(2);
      assert gx_writes = 4
         report "fresh GX request did not restart repeat DMA" severity failure;
      write_reg(x"00000DC", x"7E400002");

      -- Posted VRAM uses the same two-phase contract as GX: valid must be
      -- visible and payload held while local credit is low, but the actual
      -- nds_vram enable and DMA retirement must wait for that credit.
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      vr_welig <= '1';
      vr_wok <= '0';
      write_reg(x"00000B0", x"02003000");
      write_reg(x"00000B4", x"06000000");
      write_reg(x"00000B8", x"C4000002");
      cycles := 0;
      while vr_write_valid = '0' loop
         wait until falling_edge(clk);
         cycles := cycles + 1;
         assert cycles < 100 report "VRAM held-valid timeout" severity failure;
      end loop;
      for i in 0 to 7 loop
         wait until falling_edge(clk);
         assert vr_write_valid = '1' and vr_ena = '0' and
                vr_addr = to_unsigned(0, vr_addr'length) and
                vr_din = memory_data(x"02003000")
            report "VRAM valid/payload was not held before local acceptance"
            severity failure;
      end loop;
      assert vr_writes = 0 and irq_count = 0
         report "VRAM DMA retired before local/event acceptance" severity failure;
      vr_wok <= '1';
      wait_for_irq(1);
      assert vr_writes = 2
         report "VRAM DMA did not retire each accepted word exactly once"
         severity failure;

      report "PASS: DMA9 GX/VRAM held-valid requests survive backpressure with no pre-accept retirement, duplicate, or loss"
         severity note;
      finish;
      wait;
   end process;
end architecture;
