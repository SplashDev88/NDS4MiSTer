library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_cpu_boot_sequencer is end entity;

architecture sim of tb_nds_cpu_boot_sequencer is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal valid : std_logic := '0';
   signal cpu_reset, ready : std_logic;
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   type address_array_t is array (0 to 8) of natural;
   constant EXPECTED_ADDRESS : address_array_t :=
      (0, 13, 14, 15, 16, 17, 24, 34, 46);
   type value_array_t is array (0 to 8) of std_logic_vector(31 downto 0);
   constant EXPECTED9 : value_array_t := (
      x"02000800", x"02000800", x"03002F7C", x"02000800",
      x"02000808", x"000000D3", x"03003FC0", x"03003F80",
      x"00000CC0");
   constant EXPECTED7 : value_array_t := (
      x"02380000", x"02380000", x"0380FD80", x"02380000",
      x"02380008", x"000000D3", x"0380FFC0", x"0380FF80",
      x"00000CC0");
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_cpu_boot_sequencer port map (
      clk => clk, reset => reset, descriptor_valid => valid,
      arm9_entry => x"02000800", arm7_entry => x"02380000",
      arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
      arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
      arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
      initial_cpsr => x"000000D3", cpu_reset => cpu_reset,
      boot_ready => ready, save9 => save9, save7 => save7);

   process
   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      valid <= '1';
      wait until rising_edge(clk);
      assert save9.rst = '1' and cpu_reset = '1' and ready = '0'
         report "savestate backing registers were not cleared first" severity failure;
      for i in 0 to 8 loop
         wait until rising_edge(clk);
         assert save9.ena = '1' and save7.ena = '1' and cpu_reset = '1'
            report "CPU released during savestate writes" severity failure;
         assert to_integer(unsigned(save9.Adr)) = EXPECTED_ADDRESS(i) and
                to_integer(unsigned(save7.Adr)) = EXPECTED_ADDRESS(i)
            report "savestate address mismatch" severity failure;
         assert save9.Din = EXPECTED9(i) and save7.Din = EXPECTED7(i)
            report "savestate value mismatch" severity failure;
      end loop;
      wait until rising_edge(clk);
      assert cpu_reset = '1' and ready = '0'
         report "missing synchronous CPU load edge" severity failure;
      wait until rising_edge(clk);
      assert cpu_reset = '0' and ready = '1'
         report "CPUs were not released together" severity failure;

      valid <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;
      assert cpu_reset = '1' and save9.rst = '1'
         report "descriptor removal did not return to safe reset" severity failure;
      report "PASS: dual CPU direct-boot savestate sequence and release" severity note;
      stop;
      wait;
   end process;
end architecture;
