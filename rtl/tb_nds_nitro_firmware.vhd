-- Writable-firmware fix and test contributed by InsaneFriend (GitHub: saneFriend).
-- Testbench for the writable SPI firmware store.
-- Covers the things that would silently break the fix on hardware:
--   1. initial contents for both served regions,
--   2. fw_data STABLE and CORRECT on the cycle fw_done asserts (index/hit are
--      registered, so an early fw_done would return the previous word),
--   3. unserved addresses read all-ones (erased flash), not zeros -- zeros are
--      indistinguishable from the stub this replaced, so a failed build would
--      look exactly like a no-op one,
--   4. WRITE-THEN-READ-BACK, per byte lane. Pokemon Pearl page-programs the
--      flash and hangs if the write does not persist, which is what made the
--      first, read-only, attempt fail on hardware while every test still passed.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_nds_nitro_firmware is
end entity;

architecture sim of tb_nds_nitro_firmware is
   signal clk      : std_logic := '0';
   signal fw_addr  : std_logic_vector(15 downto 0) := (others => '0');
   signal fw_req   : std_logic := '0';
   signal fw_done  : std_logic;
   signal fw_data  : std_logic_vector(31 downto 0);
   signal fw_wr    : std_logic := '0';
   signal fw_wlane : std_logic_vector(1 downto 0) := "00";
   signal fw_wdata : std_logic_vector(7 downto 0) := (others => '0');
   signal stop     : boolean := false;
   signal errors   : integer := 0;
begin
   clk <= not clk after 5 ns when not stop else '0';

   dut : entity work.nds_nitro_firmware
      port map (clk => clk, fw_addr => fw_addr, fw_req => fw_req,
                fw_done => fw_done, fw_data => fw_data,
                fw_wr => fw_wr, fw_wlane => fw_wlane, fw_wdata => fw_wdata);

   process
      procedure fetch(word : in integer; got : out std_logic_vector(31 downto 0)) is
         variable guard : integer := 0;
      begin
         wait until rising_edge(clk);
         fw_addr <= std_logic_vector(to_unsigned(word, 16));
         fw_req  <= '1';
         wait until rising_edge(clk);
         fw_req  <= '0';
         while fw_done /= '1' and guard < 20 loop
            wait until rising_edge(clk);
            guard := guard + 1;
         end loop;
         assert fw_done = '1'
            report "fw_done never asserted for word " & integer'image(word)
            severity error;
         wait for 1 ns;
         got := fw_data;
      end procedure;

      procedure expect(word : in integer; want : in std_logic_vector(31 downto 0);
                       name : in string) is
         variable got : std_logic_vector(31 downto 0);
      begin
         fetch(word, got);
         if got /= want then
            report name & ": word " & integer'image(word) & " MISMATCH"
               severity error;
            errors <= errors + 1;
         else
            report name & " OK" severity note;
         end if;
      end procedure;

      procedure poke(word : in integer; lane : in integer;
                     value : in std_logic_vector(7 downto 0)) is
      begin
         wait until rising_edge(clk);
         fw_addr  <= std_logic_vector(to_unsigned(word, 16));
         fw_wlane <= std_logic_vector(to_unsigned(lane, 2));
         fw_wdata <= value;
         fw_wr    <= '1';
         wait until rising_edge(clk);
         fw_wr    <= '0';
         -- The write lands a cycle after the shared address decode, so let it
         -- settle before the next access.
         wait until rising_edge(clk);
         wait until rising_edge(clk);
      end procedure;
   begin
      wait for 100 ns;

      -- Initial contents. Word 2 of the melonDS image is the "MELN" identifier.
      expect(2,     x"4E4C454D", "header id");
      expect(7,     x"00002000", "header w7");
      -- Adjacent fetches catch a stale-data handshake.
      expect(2,     x"4E4C454D", "header id again");
      -- User settings: guest word address 32640 is image byte 0x1FE00.
      -- (Address the PORT by guest word address, not by internal store index.)
      expect(32640, x"01000005", "user settings @0x1FE00");
      -- Unserved gap must read erased-flash, not zero.
      expect(1000,  x"FFFFFFFF", "gap reads all-ones");
      expect(32000, x"FFFFFFFF", "gap reads all-ones 2");

      -- THE CASE THAT MATTERS: page-program a byte and read it back.
      poke(32640, 0, x"A5");
      expect(32640, x"010000A5", "write lane0 persists");
      poke(32640, 3, x"5A");
      expect(32640, x"5A0000A5", "write lane3 persists");
      poke(2, 1, x"7E");
      expect(2, x"4E4C7E4D", "write lane1 persists");

      -- A write outside both served regions must be ignored, not corrupt them.
      poke(1000, 0, x"11");
      expect(1000, x"FFFFFFFF", "unserved write ignored");
      expect(2,    x"4E4C7E4D", "served data intact after unserved write");

      if errors = 0 then
         report "TB PASS" severity note;
      else
         report "TB FAIL" severity error;
      end if;
      stop <= true;
      wait;
   end process;
end architecture;
