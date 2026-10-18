library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
entity tb_nds_host_save_profile is end entity;
architecture sim of tb_nds_host_save_profile is
   signal clk : std_logic := '0';
   signal reset, start, host_valid : std_logic := '0';
   signal code, host_code : std_logic_vector(31 downto 0) := x"45434D41";
   signal host_type, save_type : std_logic_vector(3 downto 0) := (others => '0');
   signal busy, valid, fault : std_logic;
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_host_save_profile
      port map(clk, reset, start, code, host_code, host_valid, host_type, busy, valid, save_type, fault);
   process
      procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
      procedure clear is begin reset <= '1'; tick; reset <= '0'; tick;
         assert valid = '0' and fault = '0' and busy = '0' severity failure;
      end procedure;
      procedure expect_rejection is begin start <= '1'; tick; start <= '0'; tick;
         assert fault = '1' and valid = '0' and busy = '0'
            report "invalid host profile accepted" severity failure;
      end procedure;
   begin
      clear;
      expect_rejection; -- missing profile
      clear; host_valid <= '1'; host_code <= x"FFFFFFFF"; expect_rejection;
      clear; host_code <= code; host_type <= x"8"; expect_rejection;
      for kind in 0 to 7 loop
         clear; host_type <= std_logic_vector(to_unsigned(kind,4)); start <= '1'; tick;
         assert valid = '0' and busy = '1' and save_type = host_type severity failure;
         start <= '0'; tick;
         assert valid = '1' and busy = '0' and fault = '0' severity failure;
         host_type <= x"F"; tick;
         assert unsigned(save_type) = kind report "payload was not latched" severity failure;
      end loop;
      for region in 0 to 2 loop
         clear;
         if region = 0 then code <= x"45524F55"; host_code <= x"45524F55";
         elsif region = 1 then code <= x"50524F55"; host_code <= x"50524F55";
         else code <= x"4A524F55"; host_code <= x"4A524F55"; end if;
         host_type <= x"9"; host_valid <= '1'; tick;
         start <= '1'; tick; start <= '0'; tick;
         assert valid = '1' and save_type = x"9" and fault = '0' severity failure;
      end loop;
      for region in 0 to 1 loop
         clear;
         if region = 0 then code <= x"50425855"; host_code <= x"50425855";
         else code <= x"4A425841"; host_code <= x"4A425841"; end if;
         host_type <= x"8"; tick; start <= '1'; tick; start <= '0'; tick;
         assert valid = '1' and save_type = x"8" and fault = '0' severity failure;
      end loop;
      clear; host_type <= x"9"; expect_rejection; -- wrong NAND capacity for title
      clear; host_type <= x"A"; expect_rejection; -- DSi not supported
      clear; host_type <= x"3"; start <= '1'; tick; start <= '0';
      clear; -- reset between payload and publication cancels validity
      host_valid <= '0'; expect_rejection;
      report "PASS: loader/header identity, missing and invalid profiles, all save types, payload-before-valid and reset cancellation" severity note;
      std.env.stop; wait;
   end process;
end architecture;
