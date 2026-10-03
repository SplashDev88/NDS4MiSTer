-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copy/verify ARM binaries across 128/252/256/316 MiB and the last words of
-- 512 MiB. Check small/256 MiB cycle parity and large-ROM DSi chip-ID policy.
-- Cartridge storage/tail policy is modeled here; the island enforces it.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_nds_loader_large_rom is
   generic (scenario : natural range 0 to 7 := 0;
            boot_mode : natural range 0 to 2 := 0); -- 0 copy, 1 firmware, 2 direct
end entity;

architecture sim of tb_nds_loader_large_rom is
   type word_array is array(natural range <>) of std_logic_vector(31 downto 0);
   -- Scenarios 0/1 retain the LR1 256 MiB regression unchanged; scenario 2
   -- is a 64 MiB image. Scenarios 3-7 require 512 MiB chip-ID rounding.
   constant SOURCE9 : word_array(0 to 7) :=
      (x"07FFFFF0", x"08012340", x"01FFFFF0", x"0FFFFFF0",
       x"10012340", x"10012340", x"13BFFFF0", x"10012340");
   constant SOURCE7 : word_array(0 to 7) :=
      (x"0FBFFFF0", x"0FFFFFE0", x"03FFFFE0", x"10000000",
       x"117DFFE0", x"117DFFE0", x"13C00000", x"1FFFFFE0");
   constant USED_SIZE : word_array(0 to 7) :=
      (x"10000000", x"10000000", x"04000000", x"10000020",
       x"117E0000", x"117E0000", x"13C00020", x"20000000");
   -- UnitCode is byte0x12, bit1 (=word0x10 bit17). Other header bits are
   -- deliberately nonzero so the fixture checks the correct field.
   constant UNIT_WORD : word_array(0 to 7) :=
      (x"AA02CCDD", x"AA02CCDD", x"AA02CCDD", x"AA00CCDD",
       x"AA02CCDD", x"AA02CCDD", x"AA00CCDD", x"AA00CCDD");
   constant REGION_WORD : word_array(0 to 7) :=
      (x"00000001", x"00000001", x"00000001", x"00000001",
       x"00000001", x"00000000", x"00000000", x"00000001");
   constant EXPECTED_ID : word_array(0 to 7) :=
      (x"0000FFC2", x"0000FFC2", x"00003FC2", x"0000FEC2",
       x"4000FEC2", x"0000FEC2", x"0000FEC2", x"0000FEC2");
   constant HEADER : word_array(0 to 11) :=
      (SOURCE9(scenario), x"02010001", x"02010000", x"00000020",
       SOURCE7(scenario), x"02020001", x"02020000", x"00000020",
       x"454D414E", USED_SIZE(scenario), UNIT_WORD(scenario),
       REGION_WORD(scenario));
   function header_length return natural is
   begin
      if scenario < 3 then return 10; else return 12; end if;
   end function;
   constant HEADER_WORDS : natural := header_length;
   type time_array is array(natural range <>) of time;
   constant LR1_COMPLETION : time_array(0 to 2) := (2546 ns, 546 ns, 9726 ns);
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal start : std_logic := '0';
   signal finished : boolean := false;
   signal busy, done, load_error, card_ena, card_done : std_logic := '0';
   signal arm9_entry, arm7_entry, cart_id : std_logic_vector(31 downto 0);
   signal card_addr : std_logic_vector(28 downto 2);
   signal card_rdata, rd_data : std_logic_vector(31 downto 0) := (others => '0');
   signal wr_ena, wr_rnw, wr_done : std_logic := '0';
   signal wr_addr, wr_data : std_logic_vector(31 downto 0);
   signal vfy_bad : std_logic_vector(17 downto 0);
   signal card_reads, memory_writes, memory_reads : natural := 0;
   signal header_writes, environment_writes : natural := 0;
   signal firmware_boot, direct_boot : std_logic;

   function source_address(index : natural) return unsigned is
   begin
      if index < 8 then
         return unsigned(SOURCE9(scenario)) + index * 4;
      else
         return unsigned(SOURCE7(scenario)) + (index - 8) * 4;
      end if;
   end function;

   function image_word(address : unsigned(31 downto 0))
      return std_logic_vector is
   begin
      return std_logic_vector(address) xor x"5A69A596";
   end function;
   -- Model one consistent cartridge for the initial metadata pass and the
   -- complete direct-boot header copy. CRC fields are distinct test patterns.
   function rom_word(address : unsigned(31 downto 0))
      return std_logic_vector is
   begin
      if address >= 16#20# and address < 16#40# then
         return HEADER(to_integer(address - 16#20#) / 4);
      end if;
      case to_integer(address) is
         when 16#0C# => return HEADER(8);
         when 16#10# => return UNIT_WORD(scenario);
         when 16#6C# => return x"A1B21234";
         when 16#80# => return USED_SIZE(scenario);
         when 16#15C# => return x"5678C3D4";
         when 16#1B0# => return REGION_WORD(scenario);
         when others => return image_word(address);
      end case;
   end function;

   -- Direct-boot ABI destination order, including the two mirrored ID blocks
   -- and the 0x70-byte user-settings block. Check ID and CRC payloads below.
   constant ENVIRONMENT_ADDRESSES : word_array(0 to 12) :=
      (x"02FFF800", x"02FFF804", x"02FFF808", x"02FFF850",
       x"02FFFC00", x"02FFFC04", x"02FFFC08", x"02FFFC10",
       x"02FFFC30", x"02FFFC40", x"02FFF864", x"02FFF868",
       x"02FFF874");
   function environment_address(index : natural) return unsigned is
   begin
      if index < 13 then return unsigned(ENVIRONMENT_ADDRESSES(index)); end if;
      return to_unsigned(16#02FFFC80# + (index - 13) * 4, 32);
   end function;

   function expected_card_reads return natural is
   begin
      if boot_mode = 1 then return HEADER_WORDS; end if;
      if boot_mode = 2 then return HEADER_WORDS + 32 + 92; end if;
      return HEADER_WORDS + 32;
   end function;

begin
   clk <= not clk after 5 ns when not finished else '0';
   firmware_boot <= '1' when boot_mode = 1 else '0';
   direct_boot <= '1' when boot_mode = 2 else '0';
   dut : entity work.nds_loader
   generic map (is_simu => '1', skip_copy => '0')
   port map (
      clk => clk, reset => reset, start => start, direct => direct_boot, fw_boot => firmware_boot,
      busy => busy, done => done, load_error => load_error,
      arm9_entry => arm9_entry, arm7_entry => arm7_entry, cart_id => cart_id,
      card_ena => card_ena, card_addr => card_addr, card_done => card_done,
      card_rdata => card_rdata,
      wr_ena => wr_ena, wr_rnw => wr_rnw, wr_addr => wr_addr, wr_data => wr_data,
      wr_done => wr_done, rd_data => rd_data, vfy_bad => vfy_bad, vfy_addr => open);

   memory : process(clk)
      variable ram : word_array(0 to 15) := (others => (others => '0'));
      variable wanted : unsigned(31 downto 0);
      variable index : natural;
   begin
      if rising_edge(clk) then
         card_done <= '0';
         wr_done <= '0';
         if reset = '1' then
            card_reads <= 0;
            memory_writes <= 0;
            memory_reads <= 0;
            header_writes <= 0;
            environment_writes <= 0;
            ram := (others => (others => '0'));
         else
            if card_ena = '1' then
               assert card_reads < expected_card_reads report "extra loader cartridge read" severity failure;
               if card_reads < HEADER_WORDS then
                  case card_reads is
                     when 8 => wanted := x"0000000C";
                     when 9 => wanted := x"00000080";
                     when 10 => wanted := x"00000010";
                     when 11 => wanted := x"000001B0";
                     when others => wanted := to_unsigned(16#20# + card_reads * 4, 32);
                  end case;
               elsif boot_mode = 2 and card_reads >= HEADER_WORDS + 16 and
                     card_reads < HEADER_WORDS + 16 + 92 then
                  wanted := to_unsigned((card_reads - HEADER_WORDS - 16) * 4, 32);
               elsif boot_mode = 2 and card_reads >= HEADER_WORDS + 16 + 92 then
                  wanted := source_address(card_reads - HEADER_WORDS - 16 - 92);
               else
                  wanted := source_address((card_reads - HEADER_WORDS) mod 16);
               end if;
               card_rdata <= rom_word("000" & unsigned(card_addr) & "00");
               assert card_addr = std_logic_vector(wanted(28 downto 2))
                  report "loader read " & integer'image(card_reads) &
                         " expected " & to_hstring(wanted) & " got " &
                         to_hstring("000" & card_addr & "00") severity failure;
               card_done <= '1';
               card_reads <= card_reads + 1;
            end if;
            if wr_ena = '1' then
               assert boot_mode /= 1
                  report "firmware boot unexpectedly accessed destination RAM"
                  severity failure;
               if unsigned(wr_addr) >= unsigned'(x"02FFFE00") and
                  unsigned(wr_addr) < unsigned'(x"02FFFF70") then
                  assert boot_mode = 2 and wr_rnw = '0' and memory_writes = 16
                     report "unexpected direct-boot header operation" severity failure;
                  index := to_integer(unsigned(wr_addr) - unsigned'(x"02FFFE00")) / 4;
                  assert index = header_writes
                     report "direct-boot header copy sequence mismatch" severity failure;
                  assert wr_data = rom_word(to_unsigned(index * 4, 32))
                     report "direct-boot header copy data mismatch" severity failure;
                  header_writes <= header_writes + 1;
               elsif unsigned(wr_addr) >= unsigned'(x"02FFF800") then
                  assert boot_mode = 2 and wr_rnw = '0' and header_writes = 92 and
                         environment_writes < 41
                     report "unexpected direct-boot environment operation" severity failure;
                  assert unsigned(wr_addr) = environment_address(environment_writes)
                     report "direct-boot environment destination sequence mismatch"
                     severity failure;
                  case environment_writes is
                     when 0 | 1 | 4 | 5 =>
                        assert wr_data = EXPECTED_ID(scenario)
                           report "direct-boot environment contains wrong chip ID"
                           severity failure;
                     when 2 | 6 =>
                        assert wr_data = x"12345678"
                           report "direct-boot environment contains wrong header CRCs"
                           severity failure;
                     when others => null;
                  end case;
                  environment_writes <= environment_writes + 1;
               else
                  if unsigned(wr_addr) >= unsigned'(x"02010000") and
                     unsigned(wr_addr) < unsigned'(x"02010020") then
                     index := to_integer(unsigned(wr_addr(4 downto 2)));
                  else
                     assert unsigned(wr_addr) >= unsigned'(x"02020000") and
                            unsigned(wr_addr) < unsigned'(x"02020020")
                        report "unexpected loader destination address" severity failure;
                     index := 8 + to_integer(unsigned(wr_addr(4 downto 2)));
                  end if;
                  if wr_rnw = '0' then
                     assert index = memory_writes
                        report "loader copy destination sequence mismatch" severity failure;
                     assert wr_data = image_word(source_address(index))
                        report "loader copied aliased or stale cartridge data" severity failure;
                     ram(index) := wr_data;
                     memory_writes <= memory_writes + 1;
                  else
                     assert index = memory_reads
                        report "loader verify destination sequence mismatch" severity failure;
                     rd_data <= ram(index);
                     memory_reads <= memory_reads + 1;
                  end if;
               end if;
               wr_done <= '1';
            end if;
         end if;
      end if;
   end process;

   stimulus : process
   begin
      for cycle in 1 to 4 loop wait until rising_edge(clk); end loop;
      wait until falling_edge(clk); reset <= '0'; start <= '1';
      wait until falling_edge(clk); start <= '0';
      wait until done = '1'; wait for 1 ns;
      assert busy = '0' and load_error = '0' report "loader did not complete cleanly"
         severity failure;
      assert card_reads = expected_card_reads
         report "loader cartridge read count mismatch" severity failure;
      if boot_mode = 1 then
         assert memory_writes = 0 and memory_reads = 0
            report "firmware boot did not bypass binary staging" severity failure;
      else
         assert memory_writes = 16 and memory_reads = 16
            report "loader omitted a copy or verify pass" severity failure;
         assert unsigned(vfy_bad) = 0
            report "loader verify found incorrect data" severity failure;
         assert arm9_entry = x"02010000" and arm7_entry = x"02020000"
            report "loader changed entry points" severity failure;
      end if;
      if boot_mode = 2 then
         assert header_writes = 92 and environment_writes = 41
            report "direct boot omitted header or environment writes" severity failure;
      else
         assert header_writes = 0 and environment_writes = 0
            report "non-direct boot wrote header or environment" severity failure;
      end if;
      assert cart_id = EXPECTED_ID(scenario)
         report "loader chip ID expected " & to_hstring(EXPECTED_ID(scenario)) &
                " got " & to_hstring(cart_id) severity failure;
      if scenario < 3 then
         -- Measured against preserved LR1 RTL using this fixture's identical
         -- reset/start stimulus. Catch added transaction/rounding cycles in
         -- copy/verify, firmware boot, and direct boot independently.
         assert now = LR1_COMPLETION(boot_mode)
            report "small/256 MiB loader cycle parity changed: " & time'image(now)
            severity failure;
      end if;
      report "PASS: loader 29-bit boot policy and chip ID " & to_hstring(cart_id) &
             ", scenario " & integer'image(scenario) &
             ", boot mode " & integer'image(boot_mode) & ", elapsed " & time'image(now);
      finished <= true;
      wait;
   end process;

   watchdog : process
   begin
      wait for 100 us;
      assert finished report "large-ROM loader regression timeout" severity failure;
      wait;
   end process;
end architecture;
