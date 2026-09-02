library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_dual_cpu_bus is
end entity;

architecture sim of tb_nds_dual_cpu_bus is
   signal clk, reset : std_logic := '0';
   signal a9, w9, r9 : std_logic_vector(31 downto 0) := (others => '0');
   signal rn9, en9, dn9 : std_logic := '0';
   signal ac9 : std_logic_vector(1 downto 0) := "10";
   signal a7, w7, r7 : std_logic_vector(31 downto 0) := (others => '0');
   signal rn7, en7, dn7 : std_logic := '0';
   signal ac7 : std_logic_vector(1 downto 0) := "10";
   signal ae, we, re : std_logic_vector(31 downto 0);
   signal pc9, pc7, pce : std_logic_vector(31 downto 0) := (others => '0');
   signal rne, ene, dne, cpu9e : std_logic := '0';
   signal ace : std_logic_vector(1 downto 0);
   signal dma_test_done : std_logic := '0';

   -- Reuse this existing bus bench for the slow DMA donor units. The memory
   -- model completes one request per request pulse. This tests function, not
   -- cycle-accurate DS bus timing.
   signal d9_bus, d7_bus : proc_bus_gb_type := (
      Din => (others => '0'), Dout => (others => '0'),
      Adr => (others => '0'), rnw => '1', ena => '0', done => '0',
      acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal d9_out, d7_out : std_logic_vector(31 downto 0);
   signal d9_wired_done, d7_wired_done : std_logic;
   signal d9_vblank, d9_hblank, d9_display, d9_stop_display, d9_card :
      std_logic := '0';
   signal d9_card_supported, d7_card_supported : std_logic := '1';
   signal d7_vblank, d7_card : std_logic := '0';
   signal d9_on, d9_bus_on, d7_on, d7_bus_on : std_logic;
   signal d9_mb_ena, d9_mb_rnw, d7_mb_ena, d7_mb_rnw : std_logic;
   signal d9_mb_addr, d9_mb_dout, d7_mb_addr, d7_mb_dout :
      std_logic_vector(31 downto 0);
   signal d9_mb_acc, d9_mb_low, d7_mb_acc, d7_mb_low :
      std_logic_vector(1 downto 0);
   signal d9_irq, d7_irq : std_logic_vector(3 downto 0);
   signal d9_unsupported, d7_unsupported : std_logic;
   signal d9_reads, d9_writes, d7_reads, d7_writes : natural := 0;
   signal d9_last_write, d7_last_write : std_logic_vector(31 downto 0) :=
      (others => '0');
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => a9, arm9_rnw => rn9, arm9_ena => en9, arm9_acc => ac9,
         arm9_wdata => w9, arm9_debug_pc => pc9,
         arm9_rdata => r9, arm9_done => dn9,
         arm7_addr => a7, arm7_rnw => rn7, arm7_ena => en7, arm7_acc => ac7,
         arm7_wdata => w7, arm7_debug_pc => pc7,
         arm7_rdata => r7, arm7_done => dn7,
         ext_addr => ae, ext_rnw => rne, ext_ena => ene, ext_acc => ace,
         ext_wdata => we, ext_cpu_is_arm9 => cpu9e,
         ext_debug_pc => pce,
         ext_rdata => re, ext_done => dne
      );

   dma9 : entity work.nds_dma9
      port map (
         clk => clk, reset => reset, gb_bus => d9_bus,
         wired_out => d9_out, wired_done => d9_wired_done,
         trig_vblank => d9_vblank, trig_hblank => d9_hblank,
         trig_display => d9_display, stop_display => d9_stop_display,
         trig_card => d9_card, card_supported => d9_card_supported,
         cpu_bus_idle => '1', dma_on => d9_on,
         dma_bus_on => d9_bus_on, mb_ena => d9_mb_ena,
         mb_rnw => d9_mb_rnw, mb_adr => d9_mb_addr,
         mb_acc => d9_mb_acc, mb_lowbits => d9_mb_low,
         mb_dout => d9_mb_dout, mb_din => x"A9D0A9D0",
         mb_done => d9_mb_ena, irq_dma => d9_irq,
         unsupported_mode => d9_unsupported);

   dma7 : entity work.nds_dma7
      port map (
         clk => clk, reset => reset, gb_bus => d7_bus,
         wired_out => d7_out, wired_done => d7_wired_done,
         trig_vblank => d7_vblank, trig_card => d7_card,
         card_supported => d7_card_supported,
         cpu_bus_idle => '1', dma_on => d7_on,
         dma_bus_on => d7_bus_on, mb_ena => d7_mb_ena,
         mb_rnw => d7_mb_rnw, mb_adr => d7_mb_addr,
         mb_acc => d7_mb_acc, mb_lowbits => d7_mb_low,
         mb_dout => d7_mb_dout, mb_din => x"A7D0A7D0",
         mb_done => d7_mb_ena, irq_dma => d7_irq,
         unsupported_mode => d7_unsupported);

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            d9_reads <= 0; d9_writes <= 0;
            d7_reads <= 0; d7_writes <= 0;
         else
            if d9_mb_ena = '1' then
               if d9_mb_rnw = '1' then
                  d9_reads <= d9_reads + 1;
               else
                  d9_writes <= d9_writes + 1;
                  d9_last_write <= d9_mb_dout;
               end if;
            end if;
            if d7_mb_ena = '1' then
               if d7_mb_rnw = '1' then
                  d7_reads <= d7_reads + 1;
               else
                  d7_writes <= d7_writes + 1;
                  d7_last_write <= d7_mb_dout;
               end if;
            end if;
         end if;
      end if;
   end process;

   dma_test : process
      procedure write9(
         constant addr : std_logic_vector(27 downto 0);
         constant data : std_logic_vector(31 downto 0)) is
      begin
         d9_bus.Adr <= addr; d9_bus.Din <= data; d9_bus.rnw <= '0';
         d9_bus.acc <= ACCESS_32BIT; d9_bus.bEna <= "1111";
         d9_bus.ena <= '1'; wait until rising_edge(clk);
         d9_bus.ena <= '0'; d9_bus.rnw <= '1'; d9_bus.bEna <= "0000";
         wait until rising_edge(clk); wait for 1 ns;
      end procedure;
      procedure write7(
         constant addr : std_logic_vector(27 downto 0);
         constant data : std_logic_vector(31 downto 0)) is
      begin
         d7_bus.Adr <= addr; d7_bus.Din <= data; d7_bus.rnw <= '0';
         d7_bus.acc <= ACCESS_32BIT; d7_bus.bEna <= "1111";
         d7_bus.ena <= '1'; wait until rising_edge(clk);
         d7_bus.ena <= '0'; d7_bus.rnw <= '1'; d7_bus.bEna <= "0000";
         wait until rising_edge(clk); wait for 1 ns;
      end procedure;
      procedure pulse(signal trig : out std_logic) is
      begin
         trig <= '1'; wait until rising_edge(clk); trig <= '0';
      end procedure;
      procedure wait_irq9 is
         variable seen : boolean := false;
      begin
         for i in 0 to 63 loop
            wait until rising_edge(clk); wait for 1 ns;
            if d9_irq(0) = '1' then seen := true; exit; end if;
         end loop;
         assert seen report "DMA9 transfer did not complete" severity failure;
      end procedure;
      procedure wait_irq7 is
         variable seen : boolean := false;
      begin
         for i in 0 to 63 loop
            wait until rising_edge(clk); wait for 1 ns;
            if d7_irq(0) = '1' then seen := true; exit; end if;
         end loop;
         assert seen report "DMA7 transfer did not complete" severity failure;
      end procedure;
      variable r9base, w9base, r7base, w7base : natural;
   begin
      wait until reset = '0';
      wait until rising_edge(clk);

      -- ARM9 immediate, VBlank, HBlank, card, and display-start modes.
      write9(x"00000B0", x"02000000");
      write9(x"00000B4", x"02000100");
      r9base := d9_reads; w9base := d9_writes;
      write9(x"00000B8", x"C4000001");
      wait_irq9;
      assert d9_reads = r9base + 1 and d9_writes = w9base + 1 and
             d9_last_write = x"A9D0A9D0"
         report "DMA9 immediate transfer mismatch" severity failure;

      for mode in 1 to 4 loop
         r9base := d9_reads; w9base := d9_writes;
         case mode is
            when 1 => write9(x"00000B8", x"CC000001");
            when 2 => write9(x"00000B8", x"D4000001");
            when 3 => write9(x"00000B8", x"EC000001");
            when others => write9(x"00000B8", x"DC000001");
         end case;
         for i in 0 to 2 loop wait until rising_edge(clk); end loop;
         assert d9_reads = r9base and d9_writes = w9base and d9_on = '0'
            report "DMA9 non-immediate mode ran before its trigger"
            severity failure;
         case mode is
            when 1 => pulse(d9_vblank);
            when 2 => pulse(d9_hblank);
            when 3 => pulse(d9_card);
            when others => pulse(d9_display);
         end case;
         wait_irq9;
         assert d9_reads = r9base + 1 and d9_writes = w9base + 1
            report "DMA9 triggered transfer count mismatch" severity failure;
      end loop;

      -- A display stop disables mode 3. The unit in progress completes, but
      -- the three remaining units do not start.
      r9base := d9_reads; w9base := d9_writes;
      write9(x"00000B8", x"DE000004");
      pulse(d9_display);
      wait until d9_mb_ena = '1' and d9_mb_rnw = '1';
      pulse(d9_stop_display);
      wait_irq9;
      assert d9_reads = r9base + 1 and d9_writes = w9base + 1
         report "DMA9 display stop did not finish only the active unit"
         severity failure;
      d9_bus.Adr <= x"00000B8"; wait for 1 ns;
      assert d9_out(31) = '0'
         report "DMA9 display stop did not clear enable" severity failure;

      -- Display FIFO mode 4 is not on the slow path. It must reject enable
      -- and report the unsupported mode without a memory request.
      r9base := d9_reads; w9base := d9_writes;
      write9(x"00000B8", x"E4000001");
      assert d9_unsupported = '1' and d9_out(31) = '0'
         report "DMA9 mode 4 did not fail closed" severity failure;
      for i in 0 to 3 loop wait until rising_edge(clk); end loop;
      assert d9_reads = r9base and d9_writes = w9base and d9_on = '0'
         report "DMA9 mode 4 issued a slow-path request" severity failure;

      -- The product has no card-ready or GX-FIFO trigger owner in this stage.
      -- These configurations must complete the register write with enable
      -- clear and a visible fault. They must not wait for an absent trigger.
      d9_card_supported <= '0';
      wait until rising_edge(clk); wait for 1 ns;
      write9(x"00000B8", x"EC000001");
      assert d9_unsupported = '1' and d9_out(31) = '0'
         report "DMA9 card mode without an owner did not fail closed"
         severity failure;
      write9(x"00000B8", x"FC000001");
      assert d9_unsupported = '1' and d9_out(31) = '0'
         report "DMA9 GX FIFO mode did not fail closed" severity failure;
      for i in 0 to 3 loop wait until rising_edge(clk); end loop;
      assert d9_reads = r9base and d9_writes = w9base and d9_on = '0'
         report "DMA9 unsupported trigger mode issued a request"
         severity failure;

      -- ARM7 keeps its own immediate, VBlank, and card timing encodings.
      write7(x"00000B0", x"02000200");
      write7(x"00000B4", x"02000300");
      r7base := d7_reads; w7base := d7_writes;
      write7(x"00000B8", x"C4000001"); wait_irq7;
      assert d7_reads = r7base + 1 and d7_writes = w7base + 1 and
             d7_last_write = x"A7D0A7D0"
         report "DMA7 immediate transfer mismatch" severity failure;
      r7base := d7_reads; w7base := d7_writes;
      write7(x"00000B8", x"D4000001"); pulse(d7_vblank); wait_irq7;
      assert d7_reads = r7base + 1 and d7_writes = w7base + 1
         report "DMA7 VBlank transfer mismatch" severity failure;
      r7base := d7_reads; w7base := d7_writes;
      write7(x"00000B8", x"E4000001"); pulse(d7_card); wait_irq7;
      assert d7_reads = r7base + 1 and d7_writes = w7base + 1
         report "DMA7 card transfer mismatch" severity failure;

      -- The product has no ARM7 card or WiFi/GBA-slot trigger owner. Both
      -- modes must reject enable and issue no memory request.
      r7base := d7_reads; w7base := d7_writes;
      d7_card_supported <= '0';
      wait until rising_edge(clk); wait for 1 ns;
      write7(x"00000B8", x"E4000001");
      assert d7_unsupported = '1' and d7_out(31) = '0'
         report "DMA7 card mode without an owner did not fail closed"
         severity failure;
      write7(x"00000B8", x"F4000001");
      assert d7_unsupported = '1' and d7_out(31) = '0'
         report "DMA7 WiFi/GBA-slot mode did not fail closed"
         severity failure;
      for i in 0 to 3 loop wait until rising_edge(clk); end loop;
      assert d7_reads = r7base and d7_writes = w7base and d7_on = '0'
         report "DMA7 unsupported trigger mode issued a request"
         severity failure;

      report "PASS: donor DMA slow path covers immediate, VBlank, HBlank, card, display start/stop, and fail-closed missing trigger modes"
         severity note;
      dma_test_done <= '1';
      wait;
   end process;

   process
   begin
      reset <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
      reset <= '0'; wait for 1 ns;

      -- Both CPUs request external memory together. ARM9 wins first after reset.
      a9 <= x"02000000"; pc9 <= x"02001234"; rn9 <= '1'; en9 <= '1';
      a7 <= x"03800000"; pc7 <= x"03805678"; rn7 <= '1'; en7 <= '1';
      wait until rising_edge(clk);
      en9 <= '0'; en7 <= '0'; wait for 1 ns;
      -- Request pulses are first captured into lossless per-CPU queues.
      wait until rising_edge(clk); wait for 1 ns;
      assert ene = '1' and ae = x"02000000" and cpu9e = '1' and
             pce = x"02001234"
         report "ARM9 did not win first grant with its launch PC"
         severity failure;
      re <= x"A9A9A9A9"; dne <= '1'; wait for 1 ns;
      assert dn9 = '1' and r9 = x"A9A9A9A9" report "ARM9 response mismatch" severity failure;
      wait until rising_edge(clk); dne <= '0'; wait for 1 ns;

      -- ARM7's held request receives the next grant.
      wait until rising_edge(clk); wait for 1 ns;
      pc7 <= x"DEADBEEF";
      assert ene = '1' and ae = x"03800000" and cpu9e = '0' and
             pce = x"03805678"
         report "queued ARM7 request did not retain its launch PC"
         severity failure;

      -- The bounded firmware countdown is local even while ARM7 owns the
      -- external port, avoiding one HPS round trip per polling iteration.
      a9 <= x"04000180"; rn9 <= '0'; w9 <= x"00000A00"; en9 <= '1'; wait for 1 ns;
      assert dn9 = '1' and ene = '1' and cpu9e = '0'
         report "boot IPCSYNC was not completed locally beside ARM7 traffic"
         severity failure;
      wait until rising_edge(clk); en9 <= '0'; wait for 1 ns;

      re <= x"A7A7A7A7"; dne <= '1'; wait for 1 ns;
      assert dn7 = '1' and r7 = x"A7A7A7A7" report "ARM7 response mismatch" severity failure;
      wait until rising_edge(clk); dne <= '0'; wait for 1 ns;

      -- Returning both handshake nibbles to zero ends the boot-only fast
      -- path permanently. Later IPCSYNC accesses must retain full HPS-owned
      -- interrupt semantics.
      a9 <= x"04000180"; rn9 <= '0'; w9 <= x"00000000"; en9 <= '1';
      wait for 1 ns;
      assert dn9 = '1' report "final boot IPCSYNC zero was not local" severity failure;
      wait until rising_edge(clk); en9 <= '0'; wait for 1 ns;

      a9 <= x"04000180"; rn9 <= '0'; w9 <= x"00000600"; en9 <= '1';
      wait for 1 ns;
      assert dn9 = '0' report "post-boot IPCSYNC did not return to HPS" severity failure;
      wait until rising_edge(clk); en9 <= '0'; wait for 1 ns;
      wait until rising_edge(clk); wait for 1 ns;
      assert ene = '1' and ae = x"04000180" and cpu9e = '1' and
             rne = '0' and we = x"00000600"
         report "post-boot ARM9 IPCSYNC request was not forwarded" severity failure;
      re <= x"00000000"; dne <= '1'; wait for 1 ns;
      assert dn9 = '1' report "external IPCSYNC response did not complete" severity failure;

      -- The CPU is allowed to pulse its next request on the same completion
      -- edge. This exact handoff occurs around ARM9 firmware branches.
      a9 <= x"04000208"; pc9 <= x"0200ABCD"; rn9 <= '1'; en9 <= '1';
      wait until rising_edge(clk);
      en9 <= '0'; dne <= '0'; wait for 1 ns;
      wait until rising_edge(clk); wait for 1 ns;
      pc9 <= x"CAFEBABE";
      assert ene = '1' and ae = x"04000208" and cpu9e = '1' and
             pce = x"0200ABCD"
         report "completion-coincident ARM9 request was lost" severity failure;

      wait until dma_test_done = '1';
      report "PASS: dual-CPU bus accelerates only boot IPCSYNC, restores HPS ownership, preserves completion-cycle requests, and checks both slow DMA units" severity note;
      stop;
      wait;
   end process;
end architecture;
