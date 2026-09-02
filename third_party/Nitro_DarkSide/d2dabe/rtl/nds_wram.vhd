-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- NDS shared WRAM: 32 KB, two 16 KB blocks, assigned to the CPUs by WRAMCNT
-- (byte 0x04000247, ARM9-writable; ARM7 reads it back as EXMEMSTAT companion).
--
--   WRAMCNT = 0 : ARM9 all 32 KB              / ARM7 none
--   WRAMCNT = 1 : ARM9 block 1 (0x4000..)     / ARM7 block 0
--   WRAMCNT = 2 : ARM9 block 0                / ARM7 block 1
--   WRAMCNT = 3 : ARM9 none                   / ARM7 all 32 KB
--   (melonDS NDS::MapSharedWRAM semantics; GBATEK "WRAMCNT")
--
-- Mapped windows mirror across the whole 0x03000000 region: callers pass
-- addr(14:2) and the module ignores the block bit in 16 KB modes.
-- "Unmapped" behavior is the caller's problem (ARM9: open bus; ARM7: the region
-- falls through to ARM7 private WRAM) — flagged via *_mapped.
--
-- Protocol per port: pulse ena with rnw/addr/be/din held; done pulses the next
-- cycle (reads: dout valid with done). One op in flight per port.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library MEM;

entity nds_wram is
   generic
   (
      is_simu : std_logic := '0'
   );
   port
   (
      clk         : in  std_logic;
      wramcnt     : in  std_logic_vector(1 downto 0);

      arm9_ena    : in  std_logic;
      arm9_rnw    : in  std_logic;
      arm9_addr   : in  unsigned(14 downto 2);
      arm9_be     : in  std_logic_vector(3 downto 0);
      arm9_din    : in  std_logic_vector(31 downto 0);
      arm9_dout   : out std_logic_vector(31 downto 0);
      arm9_done   : out std_logic := '0';
      arm9_mapped : out std_logic;

      arm7_ena    : in  std_logic;
      arm7_rnw    : in  std_logic;
      arm7_addr   : in  unsigned(14 downto 2);
      arm7_be     : in  std_logic_vector(3 downto 0);
      arm7_din    : in  std_logic_vector(31 downto 0);
      arm7_dout   : out std_logic_vector(31 downto 0);
      arm7_done   : out std_logic := '0';
      arm7_mapped : out std_logic
   );
end entity;

architecture arch of nds_wram is

   signal map9      : std_logic;
   signal map7      : std_logic;
   signal phys9     : unsigned(12 downto 0);
   signal phys7     : unsigned(12 downto 0);

   signal ram_dout9 : std_logic_vector(31 downto 0);
   signal ram_dout7 : std_logic_vector(31 downto 0);

begin

   -- address transform: 13-bit word address into the 8K x 32 store
   process (all)
   begin
      case wramcnt is
         when "00" =>
            map9  <= '1';                          map7  <= '0';
            phys9 <= arm9_addr(14 downto 2);       phys7 <= (others => '0');
         when "01" =>
            map9  <= '1';                          map7  <= '1';
            phys9 <= '1' & arm9_addr(13 downto 2); phys7 <= '0' & arm7_addr(13 downto 2);
         when "10" =>
            map9  <= '1';                          map7  <= '1';
            phys9 <= '0' & arm9_addr(13 downto 2); phys7 <= '1' & arm7_addr(13 downto 2);
         when others =>
            map9  <= '0';                          map7  <= '1';
            phys9 <= (others => '0');              phys7 <= arm7_addr(14 downto 2);
      end case;
   end process;

   arm9_mapped <= map9;
   arm7_mapped <= map7;

   iwramshared : entity MEM.SyncRamDualByteEnable
   generic map
   (
      is_simu     => is_simu,
      is_cyclone5 => '1',
      BYTE_WIDTH  => 8,
      BYTES       => 4,
      ADDR_WIDTH  => 13
   )
   port map
   (
      clk        => clk,

      ce_a       => arm9_ena,
      addr_a     => to_integer(phys9),
      datain_a0  => arm9_din( 7 downto  0),
      datain_a1  => arm9_din(15 downto  8),
      datain_a2  => arm9_din(23 downto 16),
      datain_a3  => arm9_din(31 downto 24),
      dataout_a  => ram_dout9,
      we_a       => (not arm9_rnw) and map9,
      be_a       => arm9_be,

      ce_b       => arm7_ena,
      addr_b     => to_integer(phys7),
      datain_b0  => arm7_din( 7 downto  0),
      datain_b1  => arm7_din(15 downto  8),
      datain_b2  => arm7_din(23 downto 16),
      datain_b3  => arm7_din(31 downto 24),
      dataout_b  => ram_dout7,
      we_b       => (not arm7_rnw) and map7,
      be_b       => arm7_be
   );

   process (clk)
   begin
      if rising_edge(clk) then
         arm9_done <= arm9_ena;
         arm7_done <= arm7_ena;
      end if;
   end process;

   arm9_dout <= ram_dout9 when map9 = '1' else (others => '0');
   arm7_dout <= ram_dout7 when map7 = '1' else (others => '0');

end architecture;
