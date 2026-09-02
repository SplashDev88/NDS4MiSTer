library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_arm9_first_external_bus is
end entity;

architecture sim of tb_nds_arm9_first_external_bus is
   signal clk : std_logic := '0';
   signal reset, descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal gb_on : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');

   signal cpu_addr, cpu_wdata, cpu_rdata : std_logic_vector(31 downto 0);
   signal cpu_rnw, cpu_ena, cpu_done : std_logic;
   signal cpu_acc : std_logic_vector(1 downto 0);
   signal execute_pc : std_logic_vector(31 downto 0);

   signal ext_addr, ext_wdata, ext_rdata, ext_debug_pc :
      std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_done, ext_cpu_is_arm9 : std_logic := '0';
   signal ext_acc : std_logic_vector(1 downto 0);
   signal response_active : std_logic := '0';
   signal response_delay : natural range 0 to 7 := 0;
   signal saw_ime_write : std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"02000800", arm7_entry => x"02380000",
         arm9_current_sp => x"03002F7C", arm9_irq_sp => x"03003F80",
         arm9_saved_sp => x"03003FC0", arm7_current_sp => x"0380FD80",
         arm7_irq_sp => x"0380FF80", arm7_saved_sp => x"0380FFC0",
         initial_cpsr => x"000000D3", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   cpu : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk, gb_on => gb_on, reset => boot_reset,
         savestate_bus => save9,
         gb_bus_Adr => cpu_addr, gb_bus_rnw => cpu_rnw,
         gb_bus_ena => cpu_ena, gb_bus_acc => cpu_acc,
         gb_bus_dout => cpu_wdata, gb_bus_din => cpu_rdata,
         gb_bus_done => cpu_done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'),
         IRP_in => (others => '0'), cpu_IRP => '0', new_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => open, debug_cpu_execute_pc => execute_pc,
         debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   bridge : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => boot_reset,
         arm9_addr => cpu_addr, arm9_rnw => cpu_rnw,
         arm9_ena => cpu_ena, arm9_acc => cpu_acc,
         arm9_wdata => cpu_wdata,
         arm9_debug_pc => execute_pc xor x"40000000",
         arm9_rdata => cpu_rdata, arm9_done => cpu_done,
         arm7_addr => (others => '0'), arm7_rnw => '1',
         arm7_ena => '0', arm7_acc => "10",
         arm7_wdata => (others => '0'),
         arm7_debug_pc => (others => '0'),
         arm7_rdata => open, arm7_done => open,
         ext_addr => ext_addr, ext_rnw => ext_rnw,
         ext_ena => ext_ena, ext_acc => ext_acc,
         ext_wdata => ext_wdata, ext_cpu_is_arm9 => ext_cpu_is_arm9,
         ext_debug_pc => ext_debug_pc,
         ext_rdata => ext_rdata, ext_done => ext_done
      );

   process(all)
   begin
      case ext_addr is
         when x"02000800" => ext_rdata <= x"E3A0C301";
         when x"02000804" => ext_rdata <= x"E58CC208";
         when x"02000808" => ext_rdata <= x"EB000093";
         when others      => ext_rdata <= (others => '0');
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if boot_reset = '1' then
            response_active <= '0';
            response_delay <= 0;
            saw_ime_write <= '0';
         elsif response_active = '1' then
            if response_delay = 0 then
               ext_done <= '1';
               response_active <= '0';
            else
               response_delay <= response_delay - 1;
            end if;
         elsif ext_ena = '1' then
            response_active <= '1';
            response_delay <= 2;
            if ext_addr = x"04000208" and ext_rnw = '0' then
               assert ext_cpu_is_arm9 = '1' and ext_acc = ACCESS_32BIT and
                      ext_wdata = x"04000000"
                  report "first ARM9 IME request payload diverged"
                  severity failure;
               assert (ext_debug_pc xor x"40000000") = x"02000804"
                  report "first ARM9 IME request execute PC diverged"
                  severity failure;
               saw_ime_write <= '1';
            end if;
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      gb_on <= '1';

      wait until saw_ime_write = '1' for 10 us;
      assert saw_ime_write = '1'
         report "ARM9 first IME write was lost before the external bus"
         severity failure;
      report "PASS: ARM9 first NSMB IME write crosses nds_dual_cpu_bus"
         severity note;
      stop;
      wait;
   end process;
end architecture;
