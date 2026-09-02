library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;

-- Synthesizable pair of DS CPU bring-up cores. Interrupts, DMA and timing
-- peripherals are intentionally tied inactive until their FPGA blocks land.
entity nds_dual_cpu_core is
   generic (
      -- Experimental default-off donor selection. The Nitro ARM9 adapter
      -- keeps the current ARM7 and all product memory/peripheral authority.
      NITRO_ARM9_ENABLE : natural range 0 to 1 := 0;
      -- Local LCD DMA pair. The disabled path keeps every legacy CPU port
      -- byte-for-byte on its former source.
      LOCAL_DMA_ENABLE : natural range 0 to 1 := 0
   );
   port (
      clk, reset : in std_logic;
      descriptor_valid : in std_logic := '0';
      arm9_entry, arm7_entry : in std_logic_vector(31 downto 0) :=
         (others => '0');
      arm9_current_sp, arm9_irq_sp, arm9_saved_sp :
         in std_logic_vector(31 downto 0) := (others => '0');
      arm7_current_sp, arm7_irq_sp, arm7_saved_sp :
         in std_logic_vector(31 downto 0) := (others => '0');
      initial_cpsr : in std_logic_vector(31 downto 0) := (others => '0');
      -- HPS mailbox service takes wall-clock time that is not part of DS
      -- emulated time. Pause both CPUs together so the non-requesting CPU
      -- cannot race thousands of cycles ahead during one oracle transaction.
      global_step_enable : in std_logic := '1';
      -- Independent safe-horizon instruction-start permits.  Defaults keep
      -- the legacy shared-pause behavior until the external-time-window path
      -- is explicitly integrated and enabled.
      arm9_step_permit : in std_logic := '1';
      arm7_step_permit : in std_logic := '1';
      boot_ready : out std_logic := '0';
      arm9_cycles, arm7_cycles : out std_logic_vector(7 downto 0);
      -- Exact normalized DS-time reports.  The legacy eight-bit ports above
      -- saturate at 255; horizon accounting must consume these wide ports.
      arm9_cycles_exact, arm7_cycles_exact :
         out std_logic_vector(8 downto 0) := (others => '0');
      arm9_cycles_valid, arm7_cycles_valid : out std_logic;
      arm9_step_boundary, arm7_step_boundary : out std_logic := '0';
      arm9_instruction_inflight, arm7_instruction_inflight :
         out std_logic := '0';
      arm9_data_waitbus, arm7_data_waitbus : out std_logic := '0';
      arm9_debug_pc, arm7_debug_pc : out std_logic_vector(31 downto 0);
      -- Dedicated diagnostic transport. Keep it separate from
      -- arm9_debug_pc because the latter is consumed functionally by the
      -- HPS peripheral model as architectural R15.
      arm9_diag_word : out std_logic_vector(31 downto 0) :=
         (others => '0');
      arm9_dtcm_region : out std_logic_vector(31 downto 0);
      arm9_dtcm_enable : out std_logic;
      arm9_addr : out std_logic_vector(31 downto 0);
      arm9_rnw, arm9_ena : out std_logic;
      arm9_acc : out std_logic_vector(1 downto 0);
      arm9_wdata : out std_logic_vector(31 downto 0);
      arm9_rdata : in std_logic_vector(31 downto 0);
      arm9_done : in std_logic;
      arm9_irq : in std_logic := '0';
      arm9_halt : in std_logic := '0';
      dma9_vblank_trigger : in std_logic := '0';
      dma9_hblank_trigger : in std_logic := '0';
      dma9_display_trigger : in std_logic := '0';
      dma9_display_stop : in std_logic := '0';
      dma9_card_trigger : in std_logic := '0';
      arm9_request_is_dma : out std_logic := '0';
      arm9_dma_irq : out std_logic_vector(3 downto 0) := (others => '0');
      arm9_dma_unsupported : out std_logic := '0';
      arm7_addr : out std_logic_vector(31 downto 0);
      arm7_rnw, arm7_ena : out std_logic;
      arm7_acc : out std_logic_vector(1 downto 0);
      arm7_wdata : out std_logic_vector(31 downto 0);
      arm7_rdata : in std_logic_vector(31 downto 0);
      arm7_done : in std_logic;
      arm7_irq : in std_logic := '0';
      arm7_halt : in std_logic := '0';
      dma7_vblank_trigger : in std_logic := '0';
      dma7_card_trigger : in std_logic := '0';
      arm7_request_is_dma : out std_logic := '0';
      arm7_dma_irq : out std_logic_vector(3 downto 0) := (others => '0');
      arm7_dma_unsupported : out std_logic := '0'
   );
end entity;

architecture rtl of nds_dual_cpu_core is
   -- A component declaration keeps default-build test flows independent of
   -- the optional donor library. The component binds only in the selected
   -- generate branch.
   component nds_nitro_arm9_adapter is
      port (
         clk, reset : in std_logic;
         savestate_bus : in proc_bus_gb_type;
         step_enable, dma_pause, irq, halt_level : in std_logic;
         address : out std_logic_vector(31 downto 0);
         read_not_write, request : out std_logic;
         bus_access : out std_logic_vector(1 downto 0);
         write_data : out std_logic_vector(31 downto 0);
         read_data : in std_logic_vector(31 downto 0);
         done : in std_logic;
         debug_pc, dtcm_region : out std_logic_vector(31 downto 0);
         dtcm_enable : out std_logic;
         cycles : out std_logic_vector(8 downto 0);
         cycles_valid, step_boundary, instruction_inflight,
            data_waitbus, dma_bus_idle : out std_logic
      );
   end component;
   signal save9, save7 : proc_bus_gb_type :=
      ((others => 'Z'), (others => 'Z'), (others => 'Z'),
       'Z', 'Z', 'Z', "ZZ", "ZZZZ", 'Z');
   signal cpu_reset : std_logic;
   signal cycles9_current, cycles7 : unsigned(7 downto 0);
   signal cycles9_exact_current, cycles7_exact : unsigned(8 downto 0);
   signal cycles9_exact_selected : unsigned(8 downto 0);
   signal cycles_valid9_current : std_logic;
   signal execute_pc9, execute_pc7, independent_execute_pc9,
      independent_execute_pc7 :
      std_logic_vector(31 downto 0);
   signal halt9_d, halt7_d : std_logic := '0';
   signal new_halt9, new_halt7, clear_halt9, clear_halt7 : std_logic;
   -- The NDS ARM9 clock is exactly twice the ARM7 clock. Both reused CPU
   -- pipelines share clk_sys, so feeding the same do_step level to each made
   -- ARM7 reach IPC responses far too early relative to ARM9. Schedule new
   -- instructions from completed cycle totals in ARM9 half-cycle units:
   -- ARM9 contributes one unit and ARM7 contributes two. Outstanding
   -- pipeline and bus-completion state still advances every clk.
   signal cycles_valid9_i, cycles_valid7_i : std_logic;
   signal arm9_scaled_cycle_sum : unsigned(9 downto 0);
   signal arm9_normalized_cycles_exact : unsigned(8 downto 0);
   signal arm9_cycle_half : unsigned(0 downto 0) := (others => '0');
   signal cycle_balance : integer range -65535 to 65535 := 0;
   signal arm9_step_enable, arm7_step_enable : std_logic;
   -- Quartus 17 does not permit reading an interface object of mode out.
   -- Keep the CPU boundary observations on internal nets, then publish them.
   signal arm9_step_boundary_i, arm7_step_boundary_i : std_logic;
   signal legacy_execute_pc9, legacy_independent_execute_pc9 :
      std_logic_vector(31 downto 0) := (others => '0');
   signal legacy_arm9_dtcm_region : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal legacy_arm9_dtcm_enable : std_logic := '0';
   signal nitro_cycles9_exact : std_logic_vector(8 downto 0) :=
      (others => '0');
   signal nitro_cycles9_valid : std_logic := '0';
   signal cpu9_addr_i, cpu9_wdata_i, cpu7_addr_i, cpu7_wdata_i :
      std_logic_vector(31 downto 0) := (others => '0');
   signal cpu9_rnw_i, cpu9_ena_i, cpu7_rnw_i, cpu7_ena_i : std_logic;
   signal cpu9_acc_i, cpu7_acc_i : std_logic_vector(1 downto 0);
   signal cpu9_rdata_i, cpu7_rdata_i : std_logic_vector(31 downto 0);
   signal cpu9_done_i, cpu7_done_i : std_logic;
   signal cpu9_lowbits, cpu7_lowbits : std_logic_vector(1 downto 0);
   signal cpu9_dma_idle, cpu7_dma_idle : std_logic := '0';
   signal dma9_regs, dma7_regs : proc_bus_gb_type :=
      (Din => (others => '0'), Dout => (others => '0'),
       Adr => (others => '0'), rnw => '1', ena => '0', done => '0',
       acc => ACCESS_32BIT, bEna => "0000", rst => '0');
   signal dma9_wired_out, dma7_wired_out : std_logic_vector(31 downto 0);
   signal dma9_wired_done, dma7_wired_done : std_logic;
   signal dma9_on, dma9_bus_on, dma7_on, dma7_bus_on : std_logic := '0';
   signal dma9_ena, dma9_rnw, dma7_ena, dma7_rnw : std_logic;
   signal dma9_addr, dma9_wdata, dma7_addr, dma7_wdata :
      std_logic_vector(31 downto 0);
   signal dma9_acc, dma9_lowbits, dma7_acc, dma7_lowbits :
      std_logic_vector(1 downto 0);
   signal dma9_rdata_hold, dma7_rdata_hold : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal dma9_rdata_in, dma7_rdata_in : std_logic_vector(31 downto 0);
   signal dma9_done_i, dma7_done_i, cpu9_reg_hit, cpu7_reg_hit : std_logic;

   function write_lanes(
      address : std_logic_vector(31 downto 0);
      acc_code : std_logic_vector(1 downto 0)) return std_logic_vector is
   begin
      if acc_code = ACCESS_8BIT then
         case address(1 downto 0) is
            when "00" => return "0001";
            when "01" => return "0010";
            when "10" => return "0100";
            when others => return "1000";
         end case;
      elsif acc_code = ACCESS_16BIT then
         if address(1) = '1' then return "1100"; else return "0011"; end if;
      else
         return "1111";
      end if;
   end function;

   function lane_write_data(
      address : std_logic_vector(31 downto 0);
      acc_code : std_logic_vector(1 downto 0);
      data : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable result : std_logic_vector(31 downto 0) := data;
   begin
      if acc_code = ACCESS_8BIT then
         result := (others => '0');
         case address(1 downto 0) is
            when "00" => result(7 downto 0) := data(7 downto 0);
            when "01" => result(15 downto 8) := data(7 downto 0);
            when "10" => result(23 downto 16) := data(7 downto 0);
            when others => result(31 downto 24) := data(7 downto 0);
         end case;
      elsif acc_code = ACCESS_16BIT and address(1) = '1' then
         result := (others => '0');
         result(31 downto 16) := data(15 downto 0);
      end if;
      return result;
   end function;

   function lane_read_data(
      address : std_logic_vector(31 downto 0);
      acc_code : std_logic_vector(1 downto 0);
      data : std_logic_vector(31 downto 0)) return std_logic_vector is
      variable result : std_logic_vector(31 downto 0) := data;
   begin
      if acc_code = ACCESS_8BIT then
         result := (others => '0');
         case address(1 downto 0) is
            when "00" => result(7 downto 0) := data(7 downto 0);
            when "01" => result(7 downto 0) := data(15 downto 8);
            when "10" => result(7 downto 0) := data(23 downto 16);
            when others => result(7 downto 0) := data(31 downto 24);
         end case;
      elsif acc_code = ACCESS_16BIT then
         result := (others => '0');
         if address(1) = '1' then
            result(15 downto 0) := data(31 downto 16);
         else
            result(15 downto 0) := data(15 downto 0);
         end if;
      end if;
      return result;
   end function;
begin
   -- Local DMA register buses use the CPU request before the flat-port mux.
   dma9_regs.Adr <= x"0" & cpu9_addr_i(23 downto 2) & "00";
   dma9_regs.rnw <= cpu9_rnw_i;
   dma9_regs.ena <= cpu9_ena_i when LOCAL_DMA_ENABLE = 1 and
      cpu9_addr_i(31 downto 24) = x"04" else '0';
   dma9_regs.acc <= cpu9_acc_i;
   dma9_regs.bEna <= write_lanes(cpu9_addr_i, cpu9_acc_i);
   dma9_regs.Din <= lane_write_data(cpu9_addr_i, cpu9_acc_i, cpu9_wdata_i);
   dma9_regs.Dout <= (others => '0');
   dma9_regs.done <= '0';
   dma9_regs.rst <= cpu_reset;
   dma7_regs.Adr <= x"0" & cpu7_addr_i(23 downto 2) & "00";
   dma7_regs.rnw <= cpu7_rnw_i;
   dma7_regs.ena <= cpu7_ena_i when LOCAL_DMA_ENABLE = 1 and
      cpu7_addr_i(31 downto 24) = x"04" else '0';
   dma7_regs.acc <= cpu7_acc_i;
   dma7_regs.bEna <= write_lanes(cpu7_addr_i, cpu7_acc_i);
   dma7_regs.Din <= lane_write_data(cpu7_addr_i, cpu7_acc_i, cpu7_wdata_i);
   dma7_regs.Dout <= (others => '0');
   dma7_regs.done <= '0';
   dma7_regs.rst <= cpu_reset;

   cpu9_reg_hit <= dma9_wired_done and cpu9_ena_i
      when LOCAL_DMA_ENABLE = 1 and cpu9_addr_i(31 downto 24) = x"04"
      else '0';
   cpu7_reg_hit <= dma7_wired_done and cpu7_ena_i
      when LOCAL_DMA_ENABLE = 1 and cpu7_addr_i(31 downto 24) = x"04"
      else '0';
   cpu9_rdata_i <= lane_read_data(cpu9_addr_i, cpu9_acc_i, dma9_wired_out)
      when cpu9_reg_hit = '1' else arm9_rdata;
   cpu7_rdata_i <= lane_read_data(cpu7_addr_i, cpu7_acc_i, dma7_wired_out)
      when cpu7_reg_hit = '1' else arm7_rdata;
   cpu9_done_i <= cpu9_reg_hit or
      (arm9_done and not dma9_bus_on) when LOCAL_DMA_ENABLE = 1 else arm9_done;
   cpu7_done_i <= cpu7_reg_hit or
      (arm7_done and not dma7_bus_on) when LOCAL_DMA_ENABLE = 1 else arm7_done;

   -- The external port has the same single owner as before. A DMA transfer
   -- replaces only its owner's CPU stream after the CPU reports a clean bus.
   arm9_addr <= dma9_addr when LOCAL_DMA_ENABLE = 1 and dma9_bus_on = '1'
      else cpu9_addr_i;
   arm9_rnw <= dma9_rnw when LOCAL_DMA_ENABLE = 1 and dma9_bus_on = '1'
      else cpu9_rnw_i;
   arm9_ena <= dma9_ena when LOCAL_DMA_ENABLE = 1 and dma9_bus_on = '1'
      else cpu9_ena_i and not cpu9_reg_hit;
   arm9_acc <= dma9_acc when LOCAL_DMA_ENABLE = 1 and dma9_bus_on = '1'
      else cpu9_acc_i;
   arm9_wdata <= dma9_wdata when LOCAL_DMA_ENABLE = 1 and dma9_bus_on = '1'
      else cpu9_wdata_i;
   arm9_request_is_dma <= dma9_bus_on when LOCAL_DMA_ENABLE = 1 else '0';
   arm7_addr <= dma7_addr when LOCAL_DMA_ENABLE = 1 and dma7_bus_on = '1'
      else cpu7_addr_i;
   arm7_rnw <= dma7_rnw when LOCAL_DMA_ENABLE = 1 and dma7_bus_on = '1'
      else cpu7_rnw_i;
   arm7_ena <= dma7_ena when LOCAL_DMA_ENABLE = 1 and dma7_bus_on = '1'
      else cpu7_ena_i and not cpu7_reg_hit;
   arm7_acc <= dma7_acc when LOCAL_DMA_ENABLE = 1 and dma7_bus_on = '1'
      else cpu7_acc_i;
   arm7_wdata <= dma7_wdata when LOCAL_DMA_ENABLE = 1 and dma7_bus_on = '1'
      else cpu7_wdata_i;
   arm7_request_is_dma <= dma7_bus_on when LOCAL_DMA_ENABLE = 1 else '0';

   dma9_done_i <= arm9_done and dma9_bus_on when LOCAL_DMA_ENABLE = 1 else '0';
   dma7_done_i <= arm7_done and dma7_bus_on when LOCAL_DMA_ENABLE = 1 else '0';
   dma9_rdata_in <= arm9_rdata when dma9_done_i = '1' else dma9_rdata_hold;
   dma7_rdata_in <= arm7_rdata when dma7_done_i = '1' else dma7_rdata_hold;
   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            dma9_rdata_hold <= (others => '0');
            dma7_rdata_hold <= (others => '0');
         else
            if dma9_done_i = '1' then dma9_rdata_hold <= arm9_rdata; end if;
            if dma7_done_i = '1' then dma7_rdata_hold <= arm7_rdata; end if;
         end if;
      end if;
   end process;

   g_dma : if LOCAL_DMA_ENABLE = 1 generate
   begin
      dma9_unit : entity work.nds_dma9
         port map (
            clk => clk, reset => cpu_reset, gb_bus => dma9_regs,
            wired_out => dma9_wired_out, wired_done => dma9_wired_done,
            trig_vblank => dma9_vblank_trigger,
            trig_hblank => dma9_hblank_trigger,
            trig_display => dma9_display_trigger,
            stop_display => dma9_display_stop,
            trig_card => dma9_card_trigger,
            -- The current product has no card-ready owner. Keep mode 5
            -- fail-closed until that trigger has an explicit owner.
            card_supported => '0',
            cpu_bus_idle => cpu9_dma_idle, dma_on => dma9_on,
            dma_bus_on => dma9_bus_on, mb_ena => dma9_ena,
            mb_rnw => dma9_rnw, mb_adr => dma9_addr,
            mb_acc => dma9_acc, mb_lowbits => dma9_lowbits,
            mb_dout => dma9_wdata, mb_din => dma9_rdata_in,
            mb_done => dma9_done_i, irq_dma => arm9_dma_irq,
            unsupported_mode => arm9_dma_unsupported);
      dma7_unit : entity work.nds_dma7
         port map (
            clk => clk, reset => cpu_reset, gb_bus => dma7_regs,
            wired_out => dma7_wired_out, wired_done => dma7_wired_done,
            trig_vblank => dma7_vblank_trigger,
            trig_card => dma7_card_trigger,
            card_supported => '0',
            cpu_bus_idle => cpu7_dma_idle, dma_on => dma7_on,
            dma_bus_on => dma7_bus_on, mb_ena => dma7_ena,
            mb_rnw => dma7_rnw, mb_adr => dma7_addr,
            mb_acc => dma7_acc, mb_lowbits => dma7_lowbits,
            mb_dout => dma7_wdata, mb_din => dma7_rdata_in,
            mb_done => dma7_done_i, irq_dma => arm7_dma_irq,
            unsupported_mode => arm7_dma_unsupported);
   end generate;

   g_no_dma : if LOCAL_DMA_ENABLE = 0 generate
   begin
      dma9_wired_out <= (others => '0');
      dma7_wired_out <= (others => '0');
      dma9_wired_done <= '0';
      dma7_wired_done <= '0';
      dma9_on <= '0'; dma9_bus_on <= '0';
      dma7_on <= '0'; dma7_bus_on <= '0';
      dma9_ena <= '0'; dma7_ena <= '0';
      dma9_rnw <= '1'; dma7_rnw <= '1';
      dma9_addr <= (others => '0'); dma7_addr <= (others => '0');
      dma9_acc <= ACCESS_32BIT; dma7_acc <= ACCESS_32BIT;
      dma9_wdata <= (others => '0'); dma7_wdata <= (others => '0');
      arm9_dma_irq <= (others => '0');
      arm7_dma_irq <= (others => '0');
      arm9_dma_unsupported <= '0';
      arm7_dma_unsupported <= '0';
   end generate;

   cycles9_exact_selected <= unsigned(nitro_cycles9_exact)
      when NITRO_ARM9_ENABLE = 1 else cycles9_exact_current;
   cycles_valid9_i <= nitro_cycles9_valid
      when NITRO_ARM9_ENABLE = 1 else cycles_valid9_current;
   -- gba_cpu reports cycles in its native CPU-clock units. ARM9 executes at
   -- twice the ARM7 clock, while the HPS scheduler accepts the shared
   -- 33.5-MHz DS timebase for either CPU. Divide ARM9 reports by two and
   -- retain an odd half-cycle so no time is lost across instruction reports.
   arm9_scaled_cycle_sum <=
      resize(cycles9_exact_selected, arm9_scaled_cycle_sum'length) +
      resize(arm9_cycle_half, arm9_scaled_cycle_sum'length);
   arm9_normalized_cycles_exact <= arm9_scaled_cycle_sum(9 downto 1);
   arm9_cycles_exact <= std_logic_vector(arm9_normalized_cycles_exact);
   arm7_cycles_exact <= std_logic_vector(cycles7_exact);
   -- Keep the historical ABI deterministic for legacy consumers.  A legal
   -- long report must saturate, never wrap to a deceptively small duration.
   arm9_cycles <= (others => '1')
      when arm9_normalized_cycles_exact > to_unsigned(255, 9)
      else std_logic_vector(arm9_normalized_cycles_exact(7 downto 0));
   arm7_cycles <= (others => '1')
      when cycles7_exact > to_unsigned(255, 9)
      else std_logic_vector(cycles7_exact(7 downto 0));
   arm9_cycles_valid <= cycles_valid9_i;
   arm7_cycles_valid <= cycles_valid7_i;
   -- Give the dedicated execute-PC path an unmistakable, reversible hardware
   -- signature at the mixed-language boundary. The HPS responder removes the
   -- corresponding CPU-specific XOR before using R15 for BIOS visibility.
   -- This prevents a retired legacy diagnostic mux from masquerading as an
   -- architectural PC in another costly hardware trace.
   -- r119 uses the independent ARM9 mixed-output seam, driven directly from
   -- execute_PCprev with no legacy telemetry mux or generic selection. This
   -- attributes a bad external address to the instruction that launched it
   -- instead of the speculative fetch address used by r117.
   -- r180 keeps the functional HPS execute-PC seam live while exporting the
   -- repeated BIOS-return snapshot on a separate diagnostic-only output.
   -- r181 uses that output for the complete R15 load address, preserving the
   -- observer-effect fix while identifying the exact corrupt input SP.
   arm9_debug_pc <= execute_pc9 xor x"40000000";
   arm9_diag_word <= independent_execute_pc9;
   arm7_debug_pc <= independent_execute_pc7 xor x"80000000";
   -- The HPS scheduler exports authoritative halt *levels*, while gba_cpu
   -- expects event pulses.  Passing either level continuously can overwrite
   -- the CPU's own interrupt-entry state.  Convert both edges to one-cycle
   -- set/release events instead.
   new_halt9 <= arm9_halt and not halt9_d;
   new_halt7 <= arm7_halt and not halt7_d;
   clear_halt9 <= not arm9_halt and halt9_d;
   clear_halt7 <= not arm7_halt and halt7_d;
   arm9_step_boundary <= arm9_step_boundary_i;
   arm7_step_boundary <= arm7_step_boundary_i;
   -- Start at most one architectural instruction at a time.  Outstanding
   -- work still advances every clk inside gba_cpu, but a CPU may only start
   -- when its peer is already at a clean boundary.  This is required by the
   -- exact blocking-MMIO stop contract: if both CPUs start together, one can
   -- retain the shared external-bus grant while the peer enters WAITBUS behind
   -- it, making the peer-clean stop predicate impossible to satisfy.  The
   -- signed cycle balance selects the lagging CPU when both are eligible and
   -- retains the existing bounded lead window when only one is runnable.
   arm9_step_enable <= global_step_enable and arm9_step_permit
      when arm7_step_boundary_i = '1' and cycle_balance <= 8 and
           (arm7_step_permit = '0' or cycle_balance <= 0)
      else '0';
   arm7_step_enable <= global_step_enable and arm7_step_permit
      when arm9_step_boundary_i = '1' and cycle_balance >= -8 and
           (arm9_step_permit = '0' or cycle_balance > 0)
      else '0';

   process (clk)
      variable next_balance : integer;
   begin
      if rising_edge(clk) then
         if cpu_reset = '1' then
            halt9_d <= '0';
            halt7_d <= '0';
            arm9_cycle_half <= (others => '0');
            cycle_balance <= 0;
         else
            halt9_d <= arm9_halt;
            halt7_d <= arm7_halt;
            if cycles_valid9_i = '1' then
               arm9_cycle_half <= arm9_scaled_cycle_sum(0 downto 0);
            end if;
            next_balance := cycle_balance;
            if cycles_valid9_i = '1' then
               next_balance := next_balance +
                  to_integer(cycles9_exact_selected);
            end if;
            if cycles_valid7_i = '1' then
               next_balance := next_balance - 2 * to_integer(cycles7_exact);
            end if;
            if next_balance > 65535 then
               cycle_balance <= 65535;
            elsif next_balance < -65535 then
               cycle_balance <= -65535;
            else
               cycle_balance <= next_balance;
            end if;
         end if;
      end if;
   end process;
   boot : entity work.nds_cpu_boot_sequencer
      port map (
         clk => clk, reset => reset, descriptor_valid => descriptor_valid,
         arm9_entry => arm9_entry, arm7_entry => arm7_entry,
         arm9_current_sp => arm9_current_sp, arm9_irq_sp => arm9_irq_sp,
         arm9_saved_sp => arm9_saved_sp, arm7_current_sp => arm7_current_sp,
         arm7_irq_sp => arm7_irq_sp, arm7_saved_sp => arm7_saved_sp,
         initial_cpsr => initial_cpsr, cpu_reset => cpu_reset,
         boot_ready => boot_ready, save9 => save9, save7 => save7
      );

   g_current_arm9 : if NITRO_ARM9_ENABLE = 0 generate
   begin
   cpu9 : entity work.gba_cpu
      generic map (
         is_simu => '0',
         is_arm9 => '1',
         -- melonDS/firmware direct-boot CP15 control state. This enables the
         -- expected ARM9 TCM/high-vector mapping before the first instruction.
         arm9_cp15_reset_control => x"00052078",
         -- r108: publish the real ARM9 PC to the HPS transaction trace.
         -- The older LR/source diagnostic mux obscures the instruction that
         -- first diverges after command 0x6B.
         arm9_bios_lr_telemetry => '0',
         -- r109: the fetch PC is speculative; correlate HPS I/O with the
         -- stable instruction currently resident in the execute stage.
         arm9_execute_pc_telemetry => '1',
         -- r155: export the stable execute PC. The external recorder now
         -- qualifies it with new_cycles_valid, producing a true retirement
         -- trace instead of the speculative fetch trace used by r151-r152.
         arm9_fetch_pc_telemetry => '0',
         -- r148 diagnostic: keep production mailbox cadence and use the
         -- telemetry enable for a frozen sixteen-PC history ending at the
         -- first 0x02005B10 white-screen-loop instruction.
         arm9_bx_lr_telemetry => '1',
         -- r153 diagnostic: preserve R2/R1/R0 and NZCV at the first proven
         -- conditional-return divergence after the cartridge transaction.
         arm9_cmp_snapshot_telemetry => '0',
         -- r154 proved the CMP/EQ sequence retires correctly. Restore the
         -- ordinary execute-PC output for the general r155 trace.
         arm9_cmp_flow_telemetry => '0',
         -- r170 proved the CMP, flags, and NE predicate chain are correct
         -- and that the second string byte is already wrong. Restore the
         -- live execute PC so r171 can attribute the source/write/read
         -- transactions that build the DTCM "BUILDTIME" buffer.
         arm9_casecmp_flow_telemetry => '0',
         -- r167 diagnostic: freeze the exact copy-alignment operands and
         -- post-TST flags at the suspected hardware/native BEQ divergence.
         -- r168 proved that path actually matches native, so restore the live
         -- execute PC for r169's deeper retirement trace.
         arm9_alignment_snapshot_telemetry => '0',
         arm9_copy_argument_telemetry => '0',
         -- r182 proved only that the failing invocation reaches its epilogue
         -- with live R11=0 while the restored SP remains correct. r183 now
         -- brackets the exact MOV r11,sp invocation and the first later,
         -- still-unrecovered R11 writer, freezing only when the known final
         -- POP uses a bad source.
         arm9_block_new_pc_telemetry => '0',
         arm9_sp_path_telemetry => '0',
         arm9_prologue_r11_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset, savestate_bus => save9,
         gb_bus_Adr => cpu9_addr_i, gb_bus_rnw => cpu9_rnw_i,
         gb_bus_ena => cpu9_ena_i, gb_bus_acc => cpu9_acc_i,
         gb_bus_dout => cpu9_wdata_i,
         gb_bus_din => cpu9_rdata_i, gb_bus_done => cpu9_done_i,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => cpu9_lowbits,
         settle => '0', dma_on => dma9_on,
         do_step => arm9_step_enable,
         done => open, CPU_bus_idle => cpu9_dma_idle,
         step_boundary_out => arm9_step_boundary_i,
         instruction_inflight_out => arm9_instruction_inflight,
         data_waitbus_out => arm9_data_waitbus, PC_in_BIOS => open,
         lastread => open, jump_out => open,
         new_cycles_out => cycles9_current,
         new_cycles_exact_out => cycles9_exact_current,
         new_cycles_valid => cycles_valid9_current,
         dma_new_cycles => '0',
         dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => arm9_irq, new_halt => new_halt9,
         clear_halt => clear_halt9,
         DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => legacy_execute_pc9,
         debug_cpu_mixed => legacy_independent_execute_pc9,
         arm9_dtcm_region => legacy_arm9_dtcm_region,
         arm9_dtcm_enable => legacy_arm9_dtcm_enable
      );
   execute_pc9 <= legacy_execute_pc9;
   independent_execute_pc9 <= legacy_independent_execute_pc9;
   arm9_dtcm_region <= legacy_arm9_dtcm_region;
   arm9_dtcm_enable <= legacy_arm9_dtcm_enable;
   end generate;

   g_nitro_arm9 : if NITRO_ARM9_ENABLE = 1 generate
   begin
      cpu9_nitro : nds_nitro_arm9_adapter
         port map (
            clk => clk,
            reset => cpu_reset,
            savestate_bus => save9,
            step_enable => arm9_step_enable,
            dma_pause => dma9_on,
            irq => arm9_irq,
            halt_level => arm9_halt,
            address => cpu9_addr_i,
            read_not_write => cpu9_rnw_i,
            request => cpu9_ena_i,
            bus_access => cpu9_acc_i,
            write_data => cpu9_wdata_i,
            read_data => cpu9_rdata_i,
            done => cpu9_done_i,
            debug_pc => execute_pc9,
            dtcm_region => arm9_dtcm_region,
            dtcm_enable => arm9_dtcm_enable,
            cycles => nitro_cycles9_exact,
            cycles_valid => nitro_cycles9_valid,
            step_boundary => arm9_step_boundary_i,
            instruction_inflight => arm9_instruction_inflight,
            data_waitbus => arm9_data_waitbus,
            dma_bus_idle => cpu9_dma_idle
         );
      independent_execute_pc9 <= execute_pc9;
   end generate;

   cpu7 : entity work.gba_cpu
      generic map (
         is_simu => '0',
         is_arm9 => '0',
         arm9_bios_lr_telemetry => '0',
         -- r135 diagnostic: r134 proves the runaway instruction is the SDK
         -- word-fill STMIA at 0x037FE670. Capture its invocation arguments
         -- and caller without changing CPU execution.
         arm7_memset_context_telemetry => '1',
         -- r128 diagnostic: cross the same independent execute-PC seam used
         -- by ARM9 so the first invalid ARM7 write can be attributed without
         -- relying on the previously aliased primary debug output.
         arm9_execute_pc_telemetry => '1'
      )
      port map (
         clk100 => clk, gb_on => '1', reset => cpu_reset, savestate_bus => save7,
         gb_bus_Adr => cpu7_addr_i, gb_bus_rnw => cpu7_rnw_i,
         gb_bus_ena => cpu7_ena_i, gb_bus_acc => cpu7_acc_i,
         gb_bus_dout => cpu7_wdata_i,
         gb_bus_din => cpu7_rdata_i, gb_bus_done => cpu7_done_i,
         wait_cnt_value => (others => '0'), wait_cnt_update => '0',
         Underclock => "00", bus_lowbits => cpu7_lowbits,
         settle => '0', dma_on => dma7_on,
         do_step => arm7_step_enable,
         done => open, CPU_bus_idle => cpu7_dma_idle,
         step_boundary_out => arm7_step_boundary_i,
         instruction_inflight_out => arm7_instruction_inflight,
         data_waitbus_out => arm7_data_waitbus, PC_in_BIOS => open,
         lastread => open, jump_out => open, new_cycles_out => cycles7,
         new_cycles_exact_out => cycles7_exact,
         new_cycles_valid => cycles_valid7_i, dma_new_cycles => '0',
         dma_first_cycles => '0',
         dma_dword_cycles => '0', dma_toROM => '0', dma_init_cycles => '0',
         dma_cycles_adrup => (others => '0'), IRP_in => (others => '0'),
         cpu_IRP => arm7_irq, new_halt => new_halt7,
         clear_halt => clear_halt7,
         DISPSTAT_debug => (others => '0'),
         debug_fifocount => 0, timerdebug0 => (others => '0'),
         timerdebug1 => (others => '0'), timerdebug2 => (others => '0'),
         timerdebug3 => (others => '0'), debug_cpu_pc => open,
         debug_cpu_execute_pc => execute_pc7,
         debug_cpu_mixed => independent_execute_pc7,
         arm9_dtcm_region => open,
         arm9_dtcm_enable => open
      );
end architecture;
