library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_filesystem_halfword_copy is
   generic (
      bus_response_delay_cycles : natural := 0
   );
end entity;

architecture sim of tb_nds_arm9_filesystem_halfword_copy is
   signal clk, reset : std_logic := '0';
   signal save : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata : std_logic_vector(31 downto 0);
   signal rnw, ena, cpu_done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal ext_addr, ext_wdata, ext_rdata, ext_debug_pc :
      std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_done, ext_cpu_is_arm9 : std_logic := '0';
   signal ext_acc : std_logic_vector(1 downto 0);
   signal dtcm_word : std_logic_vector(31 downto 0) := x"AABB6114";
   signal result_seen : std_logic := '0';
   type response_state_t is (response_idle, response_wait, response_release);
   signal response_state : response_state_t := response_idle;
   signal response_delay : natural := 0;
   signal pending_addr, pending_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending_rnw : std_logic := '1';
   signal pending_acc : std_logic_vector(1 downto 0) := ACCESS_32BIT;
begin
   clk <= not clk after 5 ns;

   -- Exercise the exact NSMB byte-copy tail:
   --   LDRH destination, LDRH source, merge low byte, STRH destination.
   -- Source 0x02096a80 contains 0x3007 and the relocated-DTCM stack word
   -- starts with low halfword 0x6114, so the architectural result is 0x6107.
   process(all)
   begin
      case ext_addr is
         when x"00000000" => ext_rdata <= x"E59F002C"; -- LDR r0,=source
         when x"00000004" => ext_rdata <= x"E59F102C"; -- LDR r1,=destination
         when x"00000008" => ext_rdata <= x"E59F402C"; -- LDR r4,=result port
         when x"0000000C" => ext_rdata <= x"E3A02001"; -- MOV r2,#1
         when x"00000010" => ext_rdata <= x"E1D120B0"; -- LDRH r2,[r1]
         when x"00000014" => ext_rdata <= x"E1D000B0"; -- LDRH r0,[r0]
         when x"00000018" => ext_rdata <= x"E2022CFF"; -- AND r2,r2,#0xff00
         when x"0000001C" => ext_rdata <= x"E20000FF"; -- AND r0,r0,#0xff
         when x"00000020" => ext_rdata <= x"E1820000"; -- ORR r0,r2,r0
         when x"00000024" => ext_rdata <= x"E1C100B0"; -- STRH r0,[r1]
         when x"00000028" => ext_rdata <= x"E5D13000"; -- LDRB r3,[r1]
         when x"0000002C" => ext_rdata <= x"E5843000"; -- STR r3,[r4]
         when x"00000030" => ext_rdata <= x"EAFFFFFE"; -- B .
         when x"00000034" => ext_rdata <= x"02096A80";
         when x"00000038" => ext_rdata <= x"027E378C";
         when x"0000003C" => ext_rdata <= x"04000000";
         when x"02096A80" => ext_rdata <= x"00003007";
         when x"027E378C" => ext_rdata <= dtcm_word;
         when others => ext_rdata <= (others => '0');
      end case;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if reset = '1' then
            dtcm_word <= x"AABB6114";
            result_seen <= '0';
            response_state <= response_idle;
            response_delay <= 0;
         else
            case response_state is
               when response_idle =>
                  if ext_ena = '1' then
                     pending_addr <= ext_addr;
                     pending_wdata <= ext_wdata;
                     pending_rnw <= ext_rnw;
                     pending_acc <= ext_acc;
                     response_delay <= bus_response_delay_cycles;
                     response_state <= response_wait;
                  end if;
               when response_wait =>
                  if response_delay > 0 then
                     response_delay <= response_delay - 1;
                  else
                     assert ext_ena = '1' and ext_addr = pending_addr and
                            ext_rnw = pending_rnw and ext_acc = pending_acc
                        report "dual-CPU bridge did not hold filesystem request"
                        severity failure;
                     ext_done <= '1';
                     if pending_rnw = '0' then
                        if pending_addr = x"027E378C" then
                           assert pending_acc = ACCESS_16BIT
                              report "filesystem copy did not issue a halfword DTCM write"
                              severity failure;
                           assert pending_wdata(15 downto 0) = x"6107"
                              report "ARM9 filesystem merge payload lost source byte 07"
                              severity failure;
                           dtcm_word(15 downto 0) <=
                              pending_wdata(15 downto 0);
                        elsif pending_addr = x"04000000" then
                           assert pending_acc = ACCESS_32BIT and
                                  pending_wdata = x"00000007"
                              report "ARM9 filesystem DTCM readback did not preserve 07"
                              severity failure;
                           result_seen <= '1';
                        end if;
                     end if;
                     response_state <= response_release;
                  end if;
               when response_release =>
                  if ext_ena = '0' then
                     response_state <= response_idle;
                  end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00052078"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => reset, savestate_bus => save,
         gb_bus_Adr => addr, gb_bus_rnw => rnw, gb_bus_ena => ena,
         gb_bus_acc => acc, gb_bus_dout => wdata, gb_bus_din => rdata,
         gb_bus_done => cpu_done, wait_cnt_value => (others => '0'),
         wait_cnt_update => '0', Underclock => "00", bus_lowbits => open,
         settle => '0', dma_on => '0', do_step => '1', done => open,
         CPU_bus_idle => open, PC_in_BIOS => open, lastread => open,
         jump_out => open, new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => '0', new_halt => '0', DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => open, debug_cpu_mixed => open,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   bridge : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => reset,
         arm9_addr => addr, arm9_rnw => rnw, arm9_ena => ena,
         arm9_acc => acc, arm9_wdata => wdata,
         arm9_debug_pc => (others => '0'),
         arm9_rdata => rdata, arm9_done => cpu_done,
         arm7_addr => (others => '0'), arm7_rnw => '1',
         arm7_ena => '0', arm7_acc => ACCESS_32BIT,
         arm7_wdata => (others => '0'),
         arm7_debug_pc => (others => '0'),
         arm7_rdata => open, arm7_done => open,
         ext_addr => ext_addr, ext_rnw => ext_rnw,
         ext_ena => ext_ena, ext_acc => ext_acc,
         ext_wdata => ext_wdata, ext_cpu_is_arm9 => ext_cpu_is_arm9,
         ext_debug_pc => ext_debug_pc,
         ext_rdata => ext_rdata, ext_done => ext_done
      );

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until result_seen = '1' for 200 us;
      assert result_seen = '1'
         report "ARM9 filesystem halfword-copy program did not complete"
         severity failure;
      report "PASS: ARM9 exact NSMB halfword-copy tail preserves byte 07"
         severity note;
      stop;
      wait;
   end process;
end architecture;
