library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.pProc_bus_gba.all;

entity tb_nds_arm7_memset_context is
   generic (
      bus_response_delay_cycles : natural := 0
   );
end entity;

architecture sim of tb_nds_arm7_memset_context is
   type responder_state_t is
      (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   signal clk100        : std_logic := '0';
   signal reset         : std_logic := '1';
   signal savestate_bus : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal bus_addr      : std_logic_vector(31 downto 0);
   signal bus_rnw       : std_logic;
   signal bus_ena       : std_logic;
   signal bus_dout      : std_logic_vector(31 downto 0);
   signal bus_din       : std_logic_vector(31 downto 0) := (others => '0');
   signal bus_done      : std_logic := '0';
   signal responder_state : responder_state_t := RESP_IDLE;
   signal pending_wait    : natural := 0;
   signal pending_addr    : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pending_rnw     : std_logic := '1';
   signal completed_writes : natural := 0;
   signal saw_return       : std_logic := '0';
   signal telemetry_word : std_logic_vector(31 downto 0);
   signal saw_r0, saw_r1, saw_r2, saw_r12, saw_lr, saw_sp :
      std_logic := '0';
begin
   clk100 <= not clk100 after 5 ns;

   process(all)
   begin
      case pending_addr is
         when x"00000000" => bus_din <= x"E59F0018"; -- LDR r0,[pc,#24]
         when x"00000004" => bus_din <= x"E59F1018"; -- LDR r1,[pc,#24]
         when x"00000008" => bus_din <= x"E59F2018"; -- LDR r2,[pc,#24]
         when x"0000000C" => bus_din <= x"E59FE018"; -- LDR lr,[pc,#24]
         when x"00000010" => bus_din <= x"E59FD018"; -- LDR sp,[pc,#24]
         when x"00000014" => bus_din <= x"E59FF018"; -- LDR pc,[pc,#24]
         when x"00000020" => bus_din <= x"00000000";
         when x"00000024" => bus_din <= x"03808670";
         when x"00000028" => bus_din <= x"000003F8";
         when x"0000002C" => bus_din <= x"00000018";
         when x"00000030" => bus_din <= x"0380FB3C";
         when x"00000034" => bus_din <= x"037FE668";
         when x"037FE668" => bus_din <= x"E081C002"; -- ADD r12,r1,r2
         when x"037FE66C" => bus_din <= x"E151000C"; -- CMP r1,r12
         when x"037FE670" => bus_din <= x"B8A10001"; -- STMIA.lt r1!,{r0}
         when x"037FE674" => bus_din <= x"BAFFFFFC"; -- BLT 0x037fe66c
         when x"037FE678" => bus_din <= x"E12FFF1E"; -- BX lr
         when x"00000018" => bus_din <= x"EAFFFFFE"; -- B .
         when others      => bus_din <= x"E1A00000";
      end case;
   end process;

   process(clk100)
   begin
      if rising_edge(clk100) then
         bus_done <= '0';
         if reset = '1' then
            responder_state <= RESP_IDLE;
            pending_wait <= 0;
            completed_writes <= 0;
            saw_return <= '0';
         else
            case responder_state is
               when RESP_IDLE =>
                  if bus_ena = '1' then
                     pending_addr <= bus_addr;
                     pending_rnw <= bus_rnw;
                     pending_wait <= bus_response_delay_cycles;
                     responder_state <= RESP_WAIT;
                     if bus_rnw = '1' and bus_addr = x"00000018" and
                        completed_writes > 0 then
                        saw_return <= '1';
                     end if;
                  end if;
               when RESP_WAIT =>
                  if pending_wait = 0 then
                     responder_state <= RESP_DONE;
                  else
                     pending_wait <= pending_wait - 1;
                  end if;
               when RESP_DONE =>
                  bus_done <= '1';
                  responder_state <= RESP_RELEASE;
                  if pending_rnw = '0' then
                     assert pending_addr >= x"03808670" and
                            pending_addr < x"03808A68"
                        report "ARM7 memset wrote beyond its valid end pointer"
                        severity failure;
                     completed_writes <= completed_writes + 1;
                  end if;
               when RESP_RELEASE =>
                  if bus_ena = '0' then
                     responder_state <= RESP_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1',
         is_arm9 => '0',
         arm9_execute_pc_telemetry => '1',
         arm7_memset_context_telemetry => '1'
      )
      port map (
         clk100 => clk100, gb_on => '1', reset => reset,
         savestate_bus => savestate_bus,
         gb_bus_Adr => bus_addr, gb_bus_rnw => bus_rnw,
         gb_bus_ena => bus_ena, gb_bus_acc => open,
         gb_bus_dout => bus_dout, gb_bus_din => bus_din,
         gb_bus_done => bus_done,
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
         debug_cpu_pc => open, debug_cpu_execute_pc => open,
         debug_cpu_mixed => telemetry_word,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk100)
   begin
      if rising_edge(clk100) then
         case telemetry_word(31 downto 28) is
            when x"A" =>
               assert telemetry_word = x"A0000000"
                  report "ARM7 memset R0 snapshot mismatch" severity failure;
               saw_r0 <= '1';
            when x"B" =>
               assert telemetry_word = x"B3808670"
                  report "ARM7 memset R1 snapshot mismatch" severity failure;
               saw_r1 <= '1';
            when x"C" =>
               assert telemetry_word = x"C00003F8"
                  report "ARM7 memset R2 snapshot mismatch" severity failure;
               saw_r2 <= '1';
            when x"D" =>
               assert telemetry_word = x"D3808A68"
                  report "ARM7 memset R12 snapshot mismatch" severity failure;
               saw_r12 <= '1';
            when x"E" =>
               assert telemetry_word = x"E0000018"
                  report "ARM7 memset LR snapshot mismatch" severity failure;
               saw_lr <= '1';
            when x"F" =>
               assert telemetry_word = x"F380FB3C"
                  report "ARM7 memset SP snapshot mismatch" severity failure;
               saw_sp <= '1';
            when others => null;
         end case;
      end if;
   end process;

   process
   begin
      wait for 40 ns;
      reset <= '0';
      wait for 5 ms;
      assert saw_r0 = '1' and saw_r1 = '1' and saw_r2 = '1' and
             saw_r12 = '1' and saw_lr = '1' and saw_sp = '1'
         report "ARM7 memset context telemetry did not cycle every snapshot"
         severity failure;
      assert saw_return = '1'
         report "ARM7 memset did not terminate at its valid end pointer"
         severity failure;
      assert completed_writes = 254
         report "ARM7 memset completed an unexpected number of writes: " &
                integer'image(completed_writes)
         severity failure;
      report "PASS: ARM7 memset context telemetry preserves arguments and caller"
         severity note;
      stop;
      wait;
   end process;
end architecture;
