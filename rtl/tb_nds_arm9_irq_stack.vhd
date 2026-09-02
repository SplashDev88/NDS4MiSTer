library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_nds_arm9_irq_stack is end entity;

architecture sim of tb_nds_arm9_irq_stack is
   type responder_state_t is (RESP_IDLE, RESP_WAIT, RESP_DONE, RESP_RELEASE);
   type stack_mem_t is array (0 to 31) of std_logic_vector(31 downto 0);
   signal clk, reset, descriptor_valid, boot_reset, boot_ready : std_logic := '0';
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal addr, wdata, rdata, debug_pc, debug_mixed :
      std_logic_vector(31 downto 0);
   signal rnw, ena, done : std_logic;
   signal acc : std_logic_vector(1 downto 0);
   signal ext_addr, ext_wdata, ext_rdata : std_logic_vector(31 downto 0);
   signal ext_rnw, ext_ena, ext_done, ext_cpu9 : std_logic;
   signal ext_acc : std_logic_vector(1 downto 0);
   signal arm7_addr, arm7_rdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal arm7_ena, arm7_done : std_logic := '0';
   signal irq : std_logic := '0';
   signal responder_state : responder_state_t := RESP_IDLE;
   signal wait_count : natural range 0 to 7 := 0;
   signal request_addr, request_wdata : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal request_rnw : std_logic := '1';
   signal irq_stack_mem : stack_mem_t := (others => x"E1510000");
   signal user_stack_mem : stack_mem_t := (others => x"E1510000");
   signal saw_irq_vector, saw_irq_stack_write, saw_user_stack_write :
      std_logic := '0';
   signal saw_function_body, saw_irq_resume, saw_function_return :
      std_logic := '0';
begin
   clk <= not clk after 5 ns;

   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => x"00000000", arm7_entry => x"00001000",
         arm9_current_sp => x"00002000", arm9_irq_sp => x"027E3FBC",
         arm9_saved_sp => x"00002000", arm7_current_sp => x"00003000",
         arm7_irq_sp => x"00003040", arm7_saved_sp => x"00003080",
         initial_cpsr => x"0000001F", cpu_reset => boot_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   process(all)
      variable index : integer;
   begin
      if ext_cpu9 = '0' then
         ext_rdata <= x"E1510000";
      elsif unsigned(request_addr) >= unsigned'(x"027E3F80") and
            unsigned(request_addr) < unsigned'(x"027E4000") then
         index := to_integer(unsigned(request_addr(6 downto 2)));
         ext_rdata <= irq_stack_mem(index);
      elsif unsigned(request_addr) >= unsigned'(x"00001F80") and
            unsigned(request_addr) < unsigned'(x"00002000") then
         index := to_integer(unsigned(request_addr(6 downto 2)));
         ext_rdata <= user_stack_mem(index);
      else
         case request_addr is
            when x"00000000" => ext_rdata <= x"E3A0001F"; -- mov r0,#0x1f
            when x"00000004" => ext_rdata <= x"E129F000"; -- msr cpsr_fc,r0
            when x"00000008" => ext_rdata <= x"EB00003C"; -- bl 0x100
            when x"0000000C" => ext_rdata <= x"EAFFFFFE"; -- b 0xc
            -- Minimal BIOS-style IRQ wrapper. The stack begins poisoned with
            -- the exact value observed as hardware's corrupt LR.
            when x"00000018" => ext_rdata <= x"E92D500F"; -- stmdb sp!,{r0-r3,r12,lr}
            when x"0000001C" => ext_rdata <= x"E8BD500F"; -- ldmia sp!,{r0-r3,r12,lr}
            when x"00000020" => ext_rdata <= x"E25EF004"; -- subs pc,lr,#4
            -- Match the hardware failure: interrupt a normal function after
            -- its user/system-bank prologue, then require its epilogue to
            -- resume on that same bank rather than the poisoned IRQ stack.
            when x"00000100" => ext_rdata <= x"E92D40F0"; -- push {r4-r7,lr}
            when x"00000104" => ext_rdata <= x"E24DD014"; -- sub sp,sp,#20
            when x"00000108" => ext_rdata <= x"E1A00000"; -- interrupted body
            when x"0000010C" => ext_rdata <= x"E28DD014"; -- add sp,sp,#20
            when x"00000110" => ext_rdata <= x"E8BD40F0"; -- pop {r4-r7,lr}
            when x"00000114" => ext_rdata <= x"E12FFF1E"; -- bx lr
            when others => ext_rdata <= x"E1A00000";
         end case;
      end if;
   end process;

   process(clk)
      variable index : integer;
   begin
      if rising_edge(clk) then
         ext_done <= '0';
         if reset = '1' then
            responder_state <= RESP_IDLE;
            wait_count <= 0;
            irq_stack_mem <= (others => x"E1510000");
            user_stack_mem <= (others => x"E1510000");
         else
            case responder_state is
               when RESP_IDLE =>
                  if ext_ena = '1' then
                     request_addr <= ext_addr;
                     request_wdata <= ext_wdata;
                     request_rnw <= ext_rnw;
                     wait_count <= 3;
                     responder_state <= RESP_WAIT;
                  end if;
               when RESP_WAIT =>
                  if wait_count = 0 then
                     responder_state <= RESP_DONE;
                  else
                     wait_count <= wait_count - 1;
                  end if;
               when RESP_DONE =>
                  if request_rnw = '0' and
                     unsigned(request_addr) >= unsigned'(x"027E3F80") and
                     unsigned(request_addr) < unsigned'(x"027E4000") then
                     index := to_integer(unsigned(request_addr(6 downto 2)));
                     irq_stack_mem(index) <= request_wdata;
                     saw_irq_stack_write <= '1';
                  elsif request_rnw = '0' and
                     unsigned(request_addr) >= unsigned'(x"00001F80") and
                     unsigned(request_addr) < unsigned'(x"00002000") then
                     index := to_integer(unsigned(request_addr(6 downto 2)));
                     user_stack_mem(index) <= request_wdata;
                     saw_user_stack_write <= '1';
                  end if;
                  ext_done <= '1';
                  responder_state <= RESP_RELEASE;
               when RESP_RELEASE =>
                  if ext_ena = '0' then responder_state <= RESP_IDLE; end if;
            end case;
         end if;
      end if;
   end process;

   router : entity work.nds_dual_cpu_bus
      port map (
         clk => clk, reset => boot_reset,
         arm9_addr => addr, arm9_rnw => rnw, arm9_ena => ena,
         arm9_acc => acc, arm9_wdata => wdata,
         arm9_debug_pc => debug_pc, arm9_rdata => rdata,
         arm9_done => done,
         arm7_addr => arm7_addr, arm7_rnw => '1', arm7_ena => arm7_ena,
         arm7_acc => ACCESS_32BIT, arm7_wdata => (others => '0'),
         arm7_debug_pc => (others => '0'),
         arm7_rdata => arm7_rdata, arm7_done => arm7_done,
         ext_addr => ext_addr, ext_rnw => ext_rnw, ext_ena => ext_ena,
         ext_acc => ext_acc, ext_wdata => ext_wdata,
         ext_cpu_is_arm9 => ext_cpu9, ext_debug_pc => open,
         ext_rdata => ext_rdata,
         ext_done => ext_done
      );

   process
   begin
      wait until boot_reset = '0';
      loop
         arm7_addr <= std_logic_vector(unsigned(arm7_addr) + 4);
         arm7_ena <= '1';
         wait until rising_edge(clk);
         arm7_ena <= '0';
         wait until arm7_done = '1';
         wait until rising_edge(clk);
      end loop;
   end process;

   dut : entity work.gba_cpu
      generic map (
         is_simu => '1', is_arm9 => '1',
         arm9_cp15_reset_control => x"00000000"
      )
      port map (
         clk100 => clk, gb_on => '1', reset => boot_reset,
         savestate_bus => save9, gb_bus_Adr => addr, gb_bus_rnw => rnw,
         gb_bus_ena => ena, gb_bus_acc => acc, gb_bus_dout => wdata,
         gb_bus_din => rdata, gb_bus_done => done,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => open, settle => '0',
         dma_on => '0', do_step => '1', done => open, CPU_bus_idle => open,
         PC_in_BIOS => open, lastread => open, jump_out => open,
         new_cycles_out => open, new_cycles_valid => open,
         dma_new_cycles => '0', dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => irq, new_halt => '0', clear_halt => '0',
         DISPSTAT_debug => (others => '0'), debug_fifocount => 0,
         timerdebug0 => (others => '0'), timerdebug1 => (others => '0'),
         timerdebug2 => (others => '0'), timerdebug3 => (others => '0'),
         debug_cpu_pc => debug_pc, debug_cpu_execute_pc => open,
         debug_cpu_mixed => debug_mixed,
         arm9_dtcm_region => open, arm9_dtcm_enable => open
      );

   process(clk)
   begin
      if rising_edge(clk) and ext_done = '1' and ext_cpu9 = '1' and
         request_rnw = '1' then
         if request_addr = x"00000018" then
            saw_irq_vector <= '1';
         elsif request_addr = x"00000108" then
            saw_function_body <= '1';
         elsif saw_irq_vector = '1' and request_addr = x"0000010C" then
            saw_irq_resume <= '1';
         elsif saw_irq_resume = '1' and request_addr = x"0000000C" then
            saw_function_return <= '1';
         end if;
      end if;
   end process;

   process
   begin
      reset <= '1';
      wait until rising_edge(clk);
      reset <= '0';
      descriptor_valid <= '1';
      wait until boot_ready = '1';
      wait until saw_function_body = '1' for 10 us;
      irq <= '1';
      wait until saw_irq_vector = '1' for 5 us;
      irq <= '0';
      wait until saw_function_return = '1' for 20 us;
      assert saw_function_body = '1'
         report "ARM9 did not reach the interruptible function body"
         severity failure;
      assert saw_irq_vector = '1'
         report "ARM9 did not enter the IRQ vector" severity failure;
      assert saw_irq_stack_write = '1'
         report "ARM9 IRQ wrapper did not save registers to its stack"
         severity failure;
      assert saw_user_stack_write = '1'
         report "ARM9 function prologue did not save its user-bank stack"
         severity failure;
      assert saw_irq_resume = '1'
         report "ARM9 IRQ return did not resume the interrupted function"
         severity failure;
      assert saw_function_return = '1'
         report "ARM9 function epilogue resumed on the wrong banked stack"
         severity failure;
      report "PASS: interrupted ARM9 function resumes on its user/system stack after delayed IRQ save/restore"
         severity note;
      stop;
      wait;
   end process;
end architecture;
