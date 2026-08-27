-- SPDX-License-Identifier: GPL-3.0-or-later
-- Focused product regression for the ARM9 2x -> GPU 1x palette/OAM bridge.
-- A legal master presents the next store on the same edge that completes the
-- previous one.  Every payload must cross once and in order; palette/OAM reads
-- remain local zero-readback operations and must not wait for a sink event.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.pProc_bus_gba.all;

entity tb_nds_nitro_pal_oam_cdc is
   generic ( CLK1X_PHASE_NS : integer := 10 );
end entity;

architecture sim of tb_nds_nitro_pal_oam_cdc is
   constant WRITE_COUNT : integer := 66;

   signal clk2x : std_logic := '0';
   signal clk1x : std_logic := '0';
   signal reset : std_logic := '1';
   signal done  : boolean := false;

   signal cpu_adr      : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_rnw      : std_logic := '1';
   signal cpu_ena      : std_logic := '0';
   signal cpu_dout     : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_din      : std_logic_vector(31 downto 0);
   signal cpu_done     : std_logic;

   signal pal_we_i9, oam_we_i9 : std_logic;
   signal pal_addr_i9, oam_addr_i9 : integer range 0 to 511;
   signal pal_din_i9, oam_din_i9 : std_logic_vector(31 downto 0);
   signal pal_be_i9, oam_be_i9 : std_logic_vector(3 downto 0);

   signal cdc_req_io, cdc_req_pal, cdc_req_oam : std_logic := '0';
   signal cdc_req_io_d, cdc_req_pal_d, cdc_req_oam_d : std_logic := '0';
   signal io9_ena, pal_we_1x, oam_we_1x : std_logic := '0';
   signal cdc_cpl, cdc_cpl_d : std_logic := '0';
   signal io_done_i9 : std_logic;

   signal sink_count : integer range 0 to WRITE_COUNT := 0;
   signal io_bus_unused : proc_bus_gb_type;
begin
   clk2x <= not clk2x after 5 ns when not done else '0';
   -- Rising edges are deliberately midway between clk2x edges.  A completion
   -- therefore becomes visible while the driver can pre-drive the successor,
   -- and the next clk2x edge both retires the old request and accepts the new.
   process
   begin
      wait for CLK1X_PHASE_NS * 1 ns;
      while not done loop
         clk1x <= '1'; wait for 10 ns;
         clk1x <= '0'; wait for 10 ns;
      end loop;
      wait;
   end process;

   dut : entity work.nds_membus9
   generic map ( is_simu => '1' )
   port map
   (
      clk => clk2x, reset => reset,
      bus_cacheable_i => '0', bus_cacheable_d => '0',
      cache_op_ena => '0', cache_op => (others => '0'),
      cache_op_addr => (others => '0'), cache_op_busy => open,
      itcm_ena => '0', itcm_load => '0', itcm_size => (others => '0'),
      dtcm_ena => '0', dtcm_load => '0',
      dtcm_base => (others => '0'), dtcm_size => (others => '0'),
      dma_bus => '0',
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena,
      cpu_code => '0', cpu_acc => ACCESS_32BIT,
      cpu_dout => cpu_dout, cpu_lowbits => cpu_adr(1 downto 0),
      cpu_lastread => x"C001D00D", cpu_din => cpu_din, cpu_done => cpu_done,
      itcm_addr => open, itcm_we => open, itcm_be => open,
      itcm_writedata => open, itcm_readdata => (others => '0'),
      dtcm_addr => open, dtcm_readdata => (others => '0'),
      dtcm_addr_b => open, dtcm_we_b => open, dtcm_be_b => open,
      dtcm_writedata_b => open,
      brom_addr => open, brom_data => (others => '0'),
      wsh_ena => open, wsh_rnw => open, wsh_addr => open, wsh_be => open,
      wsh_din => open, wsh_dout => (others => '0'),
      wsh_done => '0', wsh_mapped => '0',
      vram_ena => open, vram_rnw => open, vram_addr => open,
      vram_be => open, vram_din => open, vram_dout => (others => '0'),
      vram_done => '0',
      pal_we => pal_we_i9, pal_addr => pal_addr_i9,
      pal_din => pal_din_i9, pal_be => pal_be_i9,
      oam_we => oam_we_i9, oam_addr => oam_addr_i9,
      oam_din => oam_din_i9, oam_be => oam_be_i9,
      mr_ena => open, mr_rnw => open, mr_addr => open, mr_be => open,
      mr_writedata => open, mr_done => '0', mr_readdata => (others => '0'),
      mr_pair => open, mr_readdata_hi => (others => '0'),
      io_ce_next => '1', io_bus => io_bus_unused,
      io_wired_out => (others => '0'), io_wired_done => io_done_i9,
      dbg_mb => open, dbg_cache => open
   );

   -- Exact request-toggle and completion-toggle shape used by the product top.
   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (reset = '1') then
            cdc_req_io <= '0';
            cdc_req_pal <= '0';
            cdc_req_oam <= '0';
         else
            if (io_bus_unused.ena = '1') then cdc_req_io <= not cdc_req_io; end if;
            if (pal_we_i9 = '1') then cdc_req_pal <= not cdc_req_pal; end if;
            if (oam_we_i9 = '1') then cdc_req_oam <= not cdc_req_oam; end if;
         end if;
      end if;
   end process;

   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            cdc_req_io_d <= '0';
            cdc_req_pal_d <= '0';
            cdc_req_oam_d <= '0';
            io9_ena <= '0';
            pal_we_1x <= '0';
            oam_we_1x <= '0';
         else
            cdc_req_io_d <= cdc_req_io;
            cdc_req_pal_d <= cdc_req_pal;
            cdc_req_oam_d <= cdc_req_oam;
            io9_ena <= cdc_req_io xor cdc_req_io_d;
            pal_we_1x <= cdc_req_pal xor cdc_req_pal_d;
            oam_we_1x <= cdc_req_oam xor cdc_req_oam_d;
         end if;
      end if;
   end process;

   process (clk1x)
      variable expected : integer;
      variable expected_data : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            sink_count <= 0;
            cdc_cpl <= '0';
         else
            assert not ((io9_ena = '1' and pal_we_1x = '1') or
                        (io9_ena = '1' and oam_we_1x = '1') or
                        (pal_we_1x = '1' and oam_we_1x = '1'))
               report "IO, palette, and OAM sink pulses coalesced" severity failure;
            if (io9_ena = '1' or pal_we_1x = '1' or oam_we_1x = '1') then
               expected := sink_count;
               expected_data := x"A5000000";
               expected_data(7 downto 0) := std_logic_vector(to_unsigned(expected, 8));
               if ((expected mod 3) = 0) then
                  assert pal_we_1x = '1' and oam_we_1x = '0' and io9_ena = '0'
                     report "wrong sink selected for palette write" severity failure;
                  assert pal_addr_i9 = expected and pal_din_i9 = expected_data and pal_be_i9 = "1111"
                     report "palette payload changed before sink commit" severity failure;
               elsif ((expected mod 3) = 1) then
                  assert oam_we_1x = '1' and pal_we_1x = '0' and io9_ena = '0'
                     report "wrong sink selected for OAM write" severity failure;
                  assert oam_addr_i9 = expected and oam_din_i9 = expected_data and oam_be_i9 = "1111"
                     report "OAM payload changed before sink commit" severity failure;
               else
                  assert io9_ena = '1' and pal_we_1x = '0' and oam_we_1x = '0'
                     report "wrong sink selected for IO write" severity failure;
                  assert to_integer(unsigned(io_bus_unused.Adr)) = 16#1000# + expected * 4 and
                         io_bus_unused.Din = expected_data and io_bus_unused.bEna = "1111"
                     report "IO payload changed before sink commit" severity failure;
               end if;
               sink_count <= sink_count + 1;
               cdc_cpl <= not cdc_cpl;
            end if;
         end if;
      end if;
   end process;

   process (clk2x)
   begin
      if rising_edge(clk2x) then
         if (reset = '1') then
            cdc_cpl_d <= '0';
         else
            cdc_cpl_d <= cdc_cpl;
         end if;
      end if;
   end process;
   io_done_i9 <= cdc_cpl xor cdc_cpl_d;

   process
      variable wait_cycles : integer;
      variable before_reads : integer;
   begin
      for k in 1 to 6 loop wait until rising_edge(clk2x); end loop;
      reset <= '0';
      wait until falling_edge(clk2x);

      -- Present each successor as soon as the previous completion becomes
      -- visible.  On the donor FINISH path this makes PAL/OAM strobes adjacent
      -- clk2x cycles, which is precisely the toggle-coalescing failure mode.
      for i in 0 to WRITE_COUNT - 1 loop
         if ((i mod 3) = 0) then
            cpu_adr <= std_logic_vector(to_unsigned(16#05000000# + i * 4, 32));
         elsif ((i mod 3) = 1) then
            cpu_adr <= std_logic_vector(to_unsigned(16#07000000# + i * 4, 32));
         else
            cpu_adr <= std_logic_vector(to_unsigned(16#04001000# + i * 4, 32));
         end if;
         cpu_dout <= x"A5000000";
         cpu_dout(7 downto 0) <= std_logic_vector(to_unsigned(i, 8));
         cpu_rnw <= '0';
         cpu_ena <= '1';
         wait until rising_edge(clk2x);
         cpu_ena <= '0';
         -- A zero-gap successor is accepted while the previous transaction's
         -- completion is still high.  First wait for that old completion to
         -- fall, then wait for the newly accepted request's own completion.
         if (cpu_done = '1') then wait until cpu_done = '0'; end if;
         if (cpu_done /= '1') then wait until cpu_done = '1'; end if;
      end loop;

      -- Let the last completion retire and all CDC state settle.
      for k in 1 to 8 loop wait until rising_edge(clk2x); end loop;
      assert sink_count = WRITE_COUNT
         report "palette/OAM bridge lost or duplicated writes: committed " &
                integer'image(sink_count) & " of " & integer'image(WRITE_COUNT)
         severity failure;

      -- Readback is intentionally zero, but reads are local and must complete
      -- without producing a palette/OAM sink event.
      before_reads := sink_count;
      for i in 0 to 1 loop
         wait until falling_edge(clk2x);
         if (i = 0) then cpu_adr <= x"05000000"; else cpu_adr <= x"07000000"; end if;
         cpu_rnw <= '1';
         cpu_ena <= '1';
         wait until rising_edge(clk2x);
         cpu_ena <= '0';
         wait_cycles := 0;
         while cpu_done /= '1' and wait_cycles < 4 loop
            wait until rising_edge(clk2x);
            wait_cycles := wait_cycles + 1;
         end loop;
         assert cpu_done = '1' and cpu_din = x"00000000"
            report "palette/OAM read did not retain local FINISH behavior" severity failure;
         wait until rising_edge(clk2x);
      end loop;
      assert sink_count = before_reads
         report "palette/OAM read incorrectly generated a sink write" severity failure;

      report "PASS: 66 ordered IO/palette/OAM writes and local reads across 2x-to-1x CDC phase=" &
             integer'image(CLK1X_PHASE_NS)
         severity note;
      done <= true;
      wait;
   end process;

   process
   begin
      wait for 200 us;
      if not done then
         assert false report "palette/OAM CDC regression timeout" severity failure;
      end if;
      wait;
   end process;
end architecture;
