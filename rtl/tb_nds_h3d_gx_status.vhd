library IEEE;
use IEEE.std_logic_1164.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_h3d_gx_status is
end entity;

architecture sim of tb_nds_h3d_gx_status is
   signal clk, reset, service_ready : std_logic := '0';
   signal regs_bus : proc_bus_gb_type :=
      (Din => (others => '0'), Adr => (others => '0'), rnw => '1',
       ena => '0', acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal wired_out : std_logic_vector(31 downto 0);
   signal wired_done, trig_gx, irq_gxfifo : std_logic;
   signal fifo_level : std_logic_vector(8 downto 0) := (others => '0');
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_h3d_gx_status
      port map
      (
         clk => clk, reset => reset, service_ready => service_ready,
         fifo_level => fifo_level,
         gb_bus => regs_bus, wired_out => wired_out, wired_done => wired_done,
         trig_gx => trig_gx, irq_gxfifo => irq_gxfifo
      );

   stimulus : process
      procedure write_lane(
         constant data : std_logic_vector(31 downto 0);
         constant be   : std_logic_vector(3 downto 0)) is
      begin
         wait until falling_edge(clk);
         regs_bus.Adr <= x"0000600";
         regs_bus.Din <= data;
         regs_bus.rnw <= '0';
         regs_bus.ena <= '1';
         regs_bus.bEna <= be;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         regs_bus.ena <= '0';
         regs_bus.rnw <= '1';
         regs_bus.bEna <= "0000";
         wait for 1 ns;
      end procedure;

      procedure write_disp3dcnt(
         constant data : std_logic_vector(31 downto 0);
         constant be   : std_logic_vector(3 downto 0);
         constant acc  : std_logic_vector(1 downto 0)) is
      begin
         wait until falling_edge(clk);
         regs_bus.Adr <= x"0000060";
         regs_bus.Din <= data;
         regs_bus.rnw <= '0';
         regs_bus.ena <= '1';
         regs_bus.acc <= acc;
         regs_bus.bEna <= be;
         wait until rising_edge(clk);
         wait until falling_edge(clk);
         regs_bus.ena <= '0';
         regs_bus.rnw <= '1';
         regs_bus.acc <= ACCESS_32BIT;
         regs_bus.bEna <= "0000";
         wait for 1 ns;
      end procedure;
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';

      regs_bus.Adr <= x"0000600";
      wait for 1 ns;
      assert wired_done = '1'
         report "GXSTAT did not claim its aligned word" severity failure;
      assert wired_out(24 downto 16) = "000000000" and
             wired_out(25) = '1' and wired_out(26) = '1' and
             wired_out(31 downto 30) = "00"
         report "GXSTAT reset value was not coherent empty/below-half"
         severity failure;
      assert irq_gxfifo = '0' and trig_gx = '0'
         report "GX reset levels were incorrect" severity failure;

      -- NSMB updates DISP3DCNT through read/modify/write sequences. Preserve
      -- the writable low state, including texture-enable bit 0, while the
      -- unimplemented overflow status bits 13..12 remain clear/W1C.
      regs_bus.Adr <= x"0000060";
      wait for 1 ns;
      assert wired_done = '1' and wired_out = x"00000000"
         report "DISP3DCNT reset shadow was not claimed as zero"
         severity failure;
      write_disp3dcnt(x"00000019", "0011", ACCESS_16BIT);
      assert wired_out = x"00000019"
         report "DISP3DCNT did not retain texture-enable state"
         severity failure;
      write_disp3dcnt(x"00002019", "0011", ACCESS_16BIT);
      assert wired_out = x"00000019"
         report "DISP3DCNT bit13 W1C write corrupted retained state"
         severity failure;
      write_disp3dcnt(x"00001019", "0011", ACCESS_16BIT);
      assert wired_out = x"00000019"
         report "DISP3DCNT bit12 W1C write corrupted retained state"
         severity failure;
      write_disp3dcnt(x"00000019", "0011", ACCESS_16BIT);
      assert wired_out = x"00000019"
         report "DISP3DCNT NSMB update sequence lost texture enable"
         severity failure;

      -- Byte accesses are unimplemented by the DS GPU3D register owner: writes
      -- are ignored and reads return zero rather than exposing either byte of
      -- the halfword shadow.
      write_disp3dcnt(x"00000005", "0001", ACCESS_8BIT);
      write_disp3dcnt(x"00004A00", "0010", ACCESS_8BIT);
      assert wired_out = x"00000019"
         report "DISP3DCNT byte write changed the halfword shadow"
         severity failure;
      regs_bus.acc <= ACCESS_8BIT;
      wait for 1 ns;
      assert wired_done = '1' and wired_out = x"00000000"
         report "DISP3DCNT byte read did not return zero"
         severity failure;
      regs_bus.acc <= ACCESS_32BIT;
      wait for 1 ns;
      assert wired_out = x"00000019"
         report "DISP3DCNT byte access corrupted retained state"
         severity failure;

      -- A lower-byte write (including GXSTAT bit15's matrix-error reset lane)
      -- cannot alter the upper IRQ mode field.
      regs_bus.Adr <= x"0000600";
      write_lane(x"FFFFFFFF", "0011");
      assert wired_out(31 downto 30) = "00" and irq_gxfifo = '0'
         report "lower GXSTAT lane corrupted the IRQ mode" severity failure;

      service_ready <= '1';
      wait for 1 ns;
      assert trig_gx = '1'
         report "ready hybrid service did not request GX DMA" severity failure;

      fifo_level <= "001111111"; -- 127
      wait for 1 ns;
      assert wired_out(24 downto 16) = "001111111" and
             wired_out(25) = '1' and wired_out(26) = '0' and
             trig_gx = '1'
         report "GXSTAT level 127 threshold was incorrect" severity failure;
      fifo_level <= "010000000"; -- 128
      wait for 1 ns;
      assert wired_out(24 downto 16) = "010000000" and
             wired_out(25) = '0' and wired_out(26) = '0' and
             trig_gx = '0'
         report "GXSTAT level 128 threshold was incorrect" severity failure;
      fifo_level <= (others => '0');
      wait for 1 ns;

      -- Byte write at 0x603: mode 1 (below half) is immediately level-high.
      write_lane(x"40000000", "1000");
      assert wired_out(31 downto 30) = "01" and irq_gxfifo = '1'
         report "GXSTAT below-half IRQ mode did not assert" severity failure;
      fifo_level <= "010000000";
      wait for 1 ns;
      assert irq_gxfifo = '0'
         report "GXSTAT below-half IRQ ignored FIFO level" severity failure;
      fifo_level <= "001111111";
      wait for 1 ns;
      assert irq_gxfifo = '1'
         report "GXSTAT below-half IRQ did not reassert at level 127"
         severity failure;
      for i in 0 to 4 loop
         wait until rising_edge(clk);
         assert irq_gxfifo = '1'
            report "GX FIFO IRQ was a pulse instead of a level" severity failure;
      end loop;

      -- Upper-halfword write to mode 0 clears the level; mode 2 (empty)
      -- asserts for the same constant-empty architectural state.
      write_lane(x"00000000", "1100");
      assert irq_gxfifo = '0'
         report "GXSTAT IRQ mode 0 did not clear the level" severity failure;
      write_lane(x"80000000", "1100");
      fifo_level <= (others => '0');
      wait for 1 ns;
      assert wired_out(31 downto 30) = "10" and irq_gxfifo = '1'
         report "GXSTAT empty IRQ mode did not assert" severity failure;
      fifo_level <= "000000001";
      wait for 1 ns;
      assert irq_gxfifo = '0'
         report "GXSTAT empty IRQ remained high with one entry"
         severity failure;

      -- Mode 3 is reserved/no IRQ in melonDS and in the hardware contract.
      write_lane(x"C0000000", "1000");
      assert wired_out(31 downto 30) = "11" and irq_gxfifo = '0'
         report "reserved GXSTAT IRQ mode asserted unexpectedly" severity failure;

      service_ready <= '0';
      fifo_level <= (others => '0');
      wait for 1 ns;
      assert trig_gx = '0' and wired_out(25) = '1' and wired_out(26) = '1'
         report "service loss leaked transport state into GXSTAT" severity failure;

      -- Unsupported synchronous result/count registers remain unclaimed, so
      -- the existing IO wired-OR returns zero rather than fabricated values.
      regs_bus.Adr <= x"0000604";
      wait for 1 ns;
      assert wired_done = '0' and wired_out = x"00000000"
         report "unsupported GX result register was accidentally claimed"
         severity failure;

      report "PASS: DISP3DCNT preserves NSMB texture-enable readback; GXSTAT preserves width/lane writes, real 256-entry thresholds, service-gated DMA request, and level IRQ reassert semantics"
         severity note;
      finish;
      wait;
   end process;
end architecture;
