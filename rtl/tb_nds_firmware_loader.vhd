library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_nds_firmware_loader is
   generic (scenario : natural := 0);
end entity;
architecture test of tb_nds_firmware_loader is
   function bitval(b : boolean) return std_logic is
   begin if b then return '1'; else return '0'; end if; end;
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal start : std_logic := '0';
   signal busy, done, error, card_ena, card_done, wr_ena, wr_rnw : std_logic := '0';
   signal card_addr : std_logic_vector(28 downto 2);
   signal card_data, wr_addr, wr_data, cartid : std_logic_vector(31 downto 0);
   signal paddr : std_logic_vector(4 downto 0);
   signal pdata : std_logic_vector(31 downto 0) := (others => '0');
   signal writes, reads, profile_words : natural := 0;
   signal offset_seen, checksums_seen : boolean := false;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_loader
   generic map(is_simu => bitval(scenario /= 1), skip_copy => '1')
   port map(clk => clk, reset => reset, start => start,
      direct => bitval(scenario >= 2), fw_boot => bitval(scenario < 2),
      cart_present => bitval(scenario = 3),
      profile_valid => bitval(scenario = 3), profile_addr => paddr,
      profile_data => pdata, profile_fw_offset => x"0003FE00",
      profile_fw_checksums => x"24681357",
      busy => busy, done => done, load_error => error, cart_id => cartid,
      card_ena => card_ena, card_addr => card_addr, card_done => card_done,
      card_rdata => card_data, wr_ena => wr_ena, wr_rnw => wr_rnw,
      wr_addr => wr_addr, wr_data => wr_data, wr_done => '1');
   process(clk)
      variable expected_addr : unsigned(31 downto 0);
   begin
      if rising_edge(clk) then
         -- Intentionally synchronous lookup: catches one-word-late profiles.
         pdata <= std_logic_vector(to_unsigned(16#12340000# + to_integer(unsigned(paddr)), 32));
         card_done <= card_ena;
         if card_ena = '1' then
            reads <= reads + 1;
            assert scenario = 3 report "empty-slot loader read cartridge" severity failure;
            case to_integer(unsigned(card_addr)) is
               when 3 => card_data <= x"454D414E";
               when 9 | 10 => card_data <= x"02000000";
               when 13 | 14 => card_data <= x"037F8000";
               when 32 => card_data <= x"02000000";
               when others => card_data <= (others => '0');
            end case;
         end if;
         if wr_ena = '1' then
            writes <= writes + 1;
            if scenario = 1 then
               if writes < 1048576 then
                  expected_addr := to_unsigned(16#02000000# + writes*4, 32);
               else
                  expected_addr := to_unsigned(16#03800000# + (writes-1048576)*4, 32);
               end if;
               assert wr_rnw = '0' and wr_data = x"00000000" and unsigned(wr_addr) = expected_addr
                  report "firmware no-cart RAM clear corrupt or out of order" severity failure;
            elsif scenario = 3 then
               if unsigned(wr_addr) >= unsigned'(x"02FFFC80") and unsigned(wr_addr) < unsigned'(x"02FFFCF0") then
                  assert unsigned(wr_addr) = to_unsigned(16#02FFFC80# + profile_words*4, 32)
                     report "profile mirror destination order" severity failure;
                  assert wr_data = std_logic_vector(to_unsigned(16#12340000# + profile_words, 32))
                     report "profile mirror data/registered lookup latency" severity failure;
                  profile_words <= profile_words + 1;
               elsif wr_addr = x"02FFF868" then
                  assert wr_data = x"0003FE00" severity failure; offset_seen <= true;
               elsif wr_addr = x"02FFF874" then
                  assert wr_data = x"24681357" severity failure; checksums_seen <= true;
               end if;
            else
               assert false report "no-cart simulated loader wrote RAM" severity failure;
            end if;
         end if;
      end if;
   end process;
   process
   begin
      wait for 30 ns; wait until falling_edge(clk); reset <= '0'; start <= '1';
      wait until falling_edge(clk); start <= '0';
      wait until done = '1'; wait for 1 ns;
      assert busy = '0' and error = bitval(scenario = 2) severity failure;
      if scenario /= 3 then
         assert reads = 0 and cartid = x"FFFFFFFF" severity failure;
         if scenario = 1 then assert writes = 1064960 severity failure;
         else assert writes = 0 severity failure; end if;
      else
         assert profile_words = 28 and offset_seen and checksums_seen
            report "incomplete direct-boot effective firmware profile" severity failure;
      end if;
      report "PASS: firmware loader scenario " & integer'image(scenario);
      stop;
   end process;
   process begin wait for 100 ms; assert false report "loader timeout" severity failure; end process;
end architecture;
