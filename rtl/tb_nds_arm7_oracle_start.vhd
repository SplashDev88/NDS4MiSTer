library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_arm7_oracle_start is
   generic (
      retire_target : positive := 359
   );
end entity;

architecture sim of tb_nds_arm7_oracle_start is
   signal clk100        : std_logic := '0';
   signal gb_on         : std_logic := '0';
   signal reset         : std_logic := '0';
   signal descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save9         : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal save7         : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal bus_addr      : std_logic_vector(31 downto 0);
   signal bus_rnw       : std_logic;
   signal bus_ena       : std_logic;
   signal bus_acc       : std_logic_vector(1 downto 0);
   signal bus_dout      : std_logic_vector(31 downto 0);
   signal bus_din       : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done      : std_logic := '0';
   signal cpu_done      : std_logic;
   signal debug_pc      : std_logic_vector(31 downto 0);
   signal debug_mixed   : std_logic_vector(31 downto 0);
   signal retired_count : natural := 0;
   signal ipc_read_value : std_logic_vector(31 downto 0) := (others => '0');

   impure function oracle_read(
      constant address : std_logic_vector(31 downto 0))
      return std_logic_vector is
      file words : text open read_mode is "arm7-oracle-memory.hex";
      variable row : line;
      variable word_address, word_value : std_logic_vector(31 downto 0);
   begin
      while not endfile(words) loop
         readline(words, row);
         hread(row, word_address);
         hread(row, word_value);
         if word_address = address then
            return word_value;
         end if;
      end loop;
      return x"00000000";
   end function;
begin
   clk100 <= not clk100 after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk100, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02004800", arm7_entry => x"02380000",
         arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
         arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
         initial_cpsr => x"000000D3", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
      variable ipc_value : std_logic_vector(31 downto 0);
   begin
      ipc_value := (others => '0');
      if bus_addr = x"04000180" then
         bus_din <= ipc_read_value;
      else
         bus_din <= oracle_read(bus_addr);
      end if;
      bus_done <= bus_ena;
   end process;

   process(clk100)
   begin
      if rising_edge(clk100) then
         if cpu_done = '1' then
            retired_count <= retired_count + 1;
         end if;
      end if;
   end process;

   process
      file values : text open read_mode is "arm7-ipcsync-reads.hex";
      variable row : line;
      variable value : std_logic_vector(31 downto 0);
   begin
      if not endfile(values) then
         readline(values, row);
         hread(row, value);
         ipc_read_value <= value;
      end if;
      loop
         wait until rising_edge(clk100);
         if bus_ena = '1' and bus_rnw = '1' and
               bus_addr = x"04000180" and not endfile(values) then
            readline(values, row);
            hread(row, value);
            ipc_read_value <= value;
         end if;
      end loop;
   end process;

   dut : entity work.gba_cpu
      generic map (is_simu => '1', is_arm9 => '0')
      port map (
         clk100 => clk100, gb_on => gb_on, reset => boot_reset,
         savestate_bus => save7,
         gb_bus_Adr => bus_addr, gb_bus_rnw => bus_rnw,
         gb_bus_ena => bus_ena, gb_bus_acc => bus_acc,
         gb_bus_dout => bus_dout, gb_bus_din => bus_din,
         gb_bus_done => bus_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => cpu_done,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk100);
      wait until rising_edge(clk100);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      gb_on <= '1';

      wait until retired_count = retire_target for 5 ms;
      assert retired_count >= retire_target
         report "ARM7 did not reach the requested oracle instruction count"
         severity failure;
      report "PASS: ARM7 produced an initial boot trace for lockstep comparison"
         severity note;
      stop;
      wait;
   end process;
end architecture;
