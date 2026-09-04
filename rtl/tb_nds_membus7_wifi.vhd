-- Directed regression for the wifi I/O register file added to
-- nds_membus7.vhd (the real, synthesized ARM7 bus decoder -- unlike
-- rtl/nds_cpu_memory_system.sv, which turned out not to be part of the
-- shipping design at all; see HANDOFF_20260903_soulsilver_comm_error.md
-- section 9 for how that was discovered).
--
-- Covers all 4096 Wi-Fi RAM halfwords across the three driver patterns, plus write/readback at both halfword lanes (register offsets that land
-- in the upper vs. lower half of a 32-bit-aligned access rotate differently
-- -- this is exactly the bug the first draft of this fix had), the
-- W_PowerForce (0x040) -> W_PowerState (0x03C) / W_RFStatus (0x214) side
-- effect, that the side effect does NOT fire for an unrelated PowerForce
-- value, and that the 0x04800xxx/0x04808xxx mirrors address the same
-- register.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_membus7_wifi is
end entity;

architecture sim of tb_nds_membus7_wifi is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';

   signal cpu_adr : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_rnw : std_logic := '1';
   signal cpu_ena : std_logic := '0';
   signal cpu_acc : std_logic_vector(1 downto 0) := ACCESS_16BIT;
   signal cpu_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_lowbits : std_logic_vector(1 downto 0) := "00";
   signal cpu_lastread : std_logic_vector(31 downto 0) := (others => '0');
   signal cpu_din : std_logic_vector(31 downto 0);
   signal cpu_done : std_logic;

   signal bios_data : std_logic_vector(31 downto 0) := (others => '0');
   signal w7p_readdata : std_logic_vector(31 downto 0) := (others => '0');
   signal wsh_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal wsh_done : std_logic := '0';
   signal wsh_mapped : std_logic := '1';
   signal vram_dout : std_logic_vector(31 downto 0) := (others => '0');
   signal vram_done : std_logic := '0';
   signal mr_done : std_logic := '0';
   signal mr_readdata : std_logic_vector(31 downto 0) := (others => '0');
   signal io_wired_out : std_logic_vector(31 downto 0) := (others => '0');
   signal io_wired_done : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   dut : entity work.nds_membus7
   port map (
      clk => clk, reset => reset,
      cpu_adr => cpu_adr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena,
      cpu_acc => cpu_acc, cpu_dout => cpu_dout, cpu_lowbits => cpu_lowbits,
      cpu_lastread => cpu_lastread, cpu_din => cpu_din, cpu_done => cpu_done,
      bios_addr => open, bios_data => bios_data,
      w7p_addr => open, w7p_we => open, w7p_be => open,
      w7p_writedata => open, w7p_readdata => w7p_readdata,
      wsh_ena => open, wsh_rnw => open, wsh_addr => open, wsh_be => open,
      wsh_din => open, wsh_dout => wsh_dout, wsh_done => wsh_done,
      wsh_mapped => wsh_mapped,
      vram_ena => open, vram_rnw => open, vram_addr => open, vram_be => open,
      vram_din => open, vram_dout => vram_dout, vram_done => vram_done,
      mr_ena => open, mr_rnw => open, mr_addr => open, mr_be => open,
      mr_writedata => open, mr_done => mr_done, mr_readdata => mr_readdata,
      io_ce_next => '1', io_bus => open,
      io_wired_out => io_wired_out, io_wired_done => io_wired_done
   );

   process
      procedure txn(
         constant addr : std_logic_vector(31 downto 0);
         constant rnw  : std_logic;
         constant din  : std_logic_vector(31 downto 0)) is
      begin
         wait until rising_edge(clk);
         cpu_adr <= addr;
         cpu_rnw <= rnw;
         cpu_acc <= ACCESS_16BIT;
         cpu_dout <= din;
         cpu_lowbits <= addr(1 downto 0);
         cpu_ena <= '1';
         wait until rising_edge(clk);
         cpu_ena <= '0';
         if cpu_done = '0' then
            wait until rising_edge(clk) and cpu_done = '1';
         end if;
      end procedure;

      -- The ARM7 core always presents/consumes a 16-bit access in the LOW
      -- lane of cpu_dout/cpu_din ("the CPU emits raw low-lane data ... it
      -- only extends from the low lane", per this file's own header
      -- comment); nds_membus7 itself does the odd/even rotation into
      -- wdata/be internally based on cpu_adr(1). A testbench that put data
      -- in the upper lane for an odd offset would be modelling something no
      -- real ARM7 access ever does.
      procedure wifi_write(
         constant off : natural;
         constant val : std_logic_vector(15 downto 0)) is
         variable a : std_logic_vector(31 downto 0);
      begin
         a := x"04800000" or std_logic_vector(to_unsigned(off, 32));
         txn(a, '0', x"0000" & val);
      end procedure;

      procedure wifi_read(
         constant off : natural;
         constant expected : std_logic_vector(15 downto 0);
         constant lbl : string;
         constant use_mirror : boolean := false) is
         variable a : std_logic_vector(31 downto 0);
         variable got : std_logic_vector(15 downto 0);
      begin
         if use_mirror then
            a := x"04808000" or std_logic_vector(to_unsigned(off, 32));
         else
            a := x"04800000" or std_logic_vector(to_unsigned(off, 32));
         end if;
         txn(a, '1', x"00000000");
         got := cpu_din(15 downto 0);
         assert got = expected
            report lbl & ": read 0x" & to_hstring(got) &
                   " expected 0x" & to_hstring(expected)
            severity failure;
         wait until rising_edge(clk);
      end procedure;

      variable dummy : std_logic_vector(31 downto 0);
   begin
      wait for 40 ns;
      wait until falling_edge(clk);
      reset <= '0';

      -- 1. Write/readback at an EVEN halfword-in-word offset (0x018, low
      --    lane of its containing word).
      wifi_write(16#018#, x"5A5A");
      wifi_read(16#018#, x"5A5A", "even-offset readback");

      -- 2. Write/readback at an ODD halfword-in-word offset (0x01A, high
      --    lane) -- the exact case the first draft of this fix silently
      --    dropped.
      wifi_write(16#01A#, x"A5A5");
      wifi_read(16#01A#, x"A5A5", "odd-offset readback");

      -- 3. The three-pass self-test pattern the real driver uses, across a
      --    few representative registers spanning both lane parities.
      for i in 0 to 2 loop
         wifi_write(16#020#, x"FFFF");
         wifi_write(16#022#, x"FFFF");
      end loop;
      wifi_read(16#020#, x"FFFF", "self-test pattern (even)");
      wifi_read(16#022#, x"FFFF", "self-test pattern (odd)");

      -- 4. Mirror addressing: 0x04808xxx must reach the SAME register as
      --    0x04800xxx (melonDS's own addr &= 0x7FFE masking).
      wifi_write(16#01C#, x"1234");
      wifi_read(16#01C#, x"1234", "mirror readback", use_mirror => true);

      -- 5. W_PowerForce side effect: writing 0x8001 must set W_PowerState
      --    bits[9:8]=10 and W_RFStatus=9.
      wifi_write(16#040#, x"8001");
      wifi_read(16#03C#, x"0200", "W_PowerState after PowerForce=0x8001");
      wifi_read(16#214#, x"0009", "W_RFStatus after PowerForce=0x8001");

      -- 6. The side effect must NOT fire for an unrelated PowerForce value
      --    (bit15 clear -- force not active).
      wifi_write(16#03C#, x"0000");   -- reset PowerState to a known value
      wifi_write(16#040#, x"0000");   -- PowerForce write, force bit clear
      wifi_read(16#03C#, x"0000",
                "W_PowerState unaffected by a non-force PowerForce write");

      -- 7. Baseband register file.  The driver never addresses the baseband
      --    directly: it puts an index plus a direction nibble into W_BBCnt
      --    (0x158) and reads the answer from W_BBRead (0x15C).  Serving 0x15C
      --    from the flat wifi array returns whatever was last written to
      --    0x15C itself (zero), which makes BB register 0x00 read back 0x00
      --    instead of the baseband chip ID 0x6D -- the value SoulSilver's
      --    wireless init checks before it will proceed past the main menu.
      wifi_write(16#158#, x"6000");                 -- select BB reg 0x00, read
      wifi_read(16#15C#, x"006D", "BB chip ID (reg 0x00) must read 0x6D");

      -- 8. Read-only baseband registers keep their melonDS BBREG_FIXED values.
      wifi_write(16#158#, x"605D");
      wifi_read(16#15C#, x"0001", "BB reg 0x5D fixed value");
      wifi_write(16#158#, x"6064");
      wifi_read(16#15C#, x"00FF", "BB reg 0x64 fixed value");

      -- 9. A writable baseband register round-trips through W_BBWrite.
      wifi_write(16#15A#, x"0055");                 -- W_BBWrite = 0x55
      wifi_write(16#158#, x"5001");                 -- commit into BB reg 0x01
      wifi_write(16#158#, x"6001");                 -- select it for reading
      wifi_read(16#15C#, x"0055", "writable BB reg round-trip");

      -- 10. A write aimed at a read-only id is dropped, not stored.
      wifi_write(16#15A#, x"00AA");
      wifi_write(16#158#, x"5000");                 -- reg 0x00 is read-only
      wifi_write(16#158#, x"6000");
      wifi_read(16#15C#, x"006D", "read-only BB reg must reject writes");

      -- 11. A W_BBCnt whose direction nibble is not "read" answers 0.
      wifi_write(16#158#, x"0000");
      wifi_read(16#15C#, x"0000", "BB read with a bad direction code");

      -- 12. The two ports the driver spins on are hardwired "never busy";
      --     melonDS returns 0 for both and the polls only exit on that.
      wifi_write(16#15E#, x"FFFF");
      wifi_read(16#15E#, x"0000", "W_BBBusy always reads 0");
      wifi_write(16#180#, x"FFFF");
      wifi_read(16#180#, x"0000", "W_RFBusy always reads 0");

      -- 13. The 8 KiB wifi RAM at 0x4000-0x5FFF.  This is the region whose
      --     absence caused the bug: the driver memory-tests it at power-on
      --     and declares the wireless hardware dead if the test fails.
      --     Reproduce all three passes it actually runs, including the
      --     unique-per-address pass that catches aliasing.
      for i in 0 to 4095 loop
         wifi_write(16#4000# + i * 2, x"5A5A");
      end loop;
      for i in 0 to 4095 loop
         wifi_read(16#4000# + i * 2, x"5A5A", "wifi RAM pass 1 (0x5A5A)");
      end loop;
      for i in 0 to 4095 loop
         wifi_write(16#4000# + i * 2, x"A5A5");
      end loop;
      for i in 0 to 4095 loop
         wifi_read(16#4000# + i * 2, x"A5A5", "wifi RAM pass 2 (0xA5A5)");
      end loop;
      -- Pass 3: a distinct value per halfword, exactly as the driver does
      -- (0xFFFF at 0x4000 counting down).  A single shared register, or an
      -- aliasing index, passes passes 1 and 2 and fails only here.
      for i in 0 to 4095 loop
         wifi_write(16#4000# + i * 2,
                    std_logic_vector(to_unsigned(16#FFFF# - i, 16)));
      end loop;
      for i in 0 to 4095 loop
         wifi_read(16#4000# + i * 2,
                   std_logic_vector(to_unsigned(16#FFFF# - i, 16)),
                   "wifi RAM pass 3 (unique per address)");
      end loop;

      -- 14. The top and bottom of the RAM window are distinct storage, and
      --     the window does not wrap into the register file.
      wifi_write(16#5FFE#, x"1234");
      wifi_write(16#4000#, x"ABCD");
      wifi_read(16#5FFE#, x"1234", "wifi RAM top halfword");
      wifi_read(16#4000#, x"ABCD", "wifi RAM bottom halfword");

      -- 15. 0x2000-0x3FFF reads all-ones and swallows writes (melonDS).
      wifi_write(16#2000#, x"0000");
      wifi_read(16#2000#, x"FFFF", "0x2000-0x3FFF reads 0xFFFF");

      -- 16. A wifi-RAM write must not disturb the register file, even when
      --     its low address bits alias a register index (0x4000 + 0x03C).
      wifi_write(16#158#, x"6000");
      wifi_write(16#403C#, x"DEAD");
      wifi_read(16#15C#, x"006D", "BB chip ID survives an aliasing RAM write");
      wifi_read(16#403C#, x"DEAD", "aliasing RAM address keeps its own value");

      -- 17. Bit 15 mirrors the entire 32 KiB Wi-Fi aperture, including RAM.
      --     A read at 0xC002 therefore observes a write at 0x4002.
      wifi_write(16#4002#, x"CAFE");
      wifi_read(16#4002#, x"CAFE", "wifi RAM bit-15 mirror",
                use_mirror => true);

      -- 18. Addresses outside the register, FFFF, and RAM subregions read
      --     zero and swallow writes. This pins the 0x6000-0x7FFE behavior.
      wifi_write(16#6000#, x"BEEF");
      wifi_read(16#6000#, x"0000", "unused wifi window reads zero");

      -- 19. A console reset resets the bus state machine but does not erase
      --     the physical Wi-Fi RAM/register storage. This covers ROM reselect
      --     and reset behavior separately from FPGA reconfiguration.
      wait until falling_edge(clk);
      reset <= '1';
      wait for 40 ns;
      wait until falling_edge(clk);
      reset <= '0';
      wifi_read(16#4002#, x"CAFE", "wifi RAM survives console reset");
      wifi_read(16#01C#, x"1234", "wifi register survives console reset");

      report "PASS: nds_membus7 wifi register file matches spec";
      finish;
   end process;
end architecture;
