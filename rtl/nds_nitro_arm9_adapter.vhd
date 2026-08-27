-- Experimental NDS4MiSTer adapter for the Nitro_DarkSide ARM946E-S and its
-- local memory island.
--
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Nitro donor source and license: third_party/Nitro_DarkSide/SOURCE.md

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;

library nitro_arm9;
use nitro_arm9.pProc_bus_gba.all;

library MEM;

entity nds_nitro_arm9_adapter is
   port (
      clk, reset : in std_logic;
      savestate_bus : in work.pProc_bus_gba.proc_bus_gb_type;
      step_enable : in std_logic := '1';
      dma_pause : in std_logic := '0';
      irq : in std_logic := '0';
      halt_level : in std_logic := '0';

      -- Cold requests use the unchanged r343 ARM9 memory/oracle boundary.
      address : out std_logic_vector(31 downto 0);
      read_not_write, request : out std_logic;
      bus_access : out std_logic_vector(1 downto 0);
      write_data : out std_logic_vector(31 downto 0);
      read_data : in std_logic_vector(31 downto 0);
      done : in std_logic;

      debug_pc : out std_logic_vector(31 downto 0);
      dtcm_region : out std_logic_vector(31 downto 0);
      dtcm_enable : out std_logic;
      cycles : out std_logic_vector(8 downto 0) := (others => '0');
      cycles_valid : out std_logic := '0';
      step_boundary : out std_logic := '0';
      instruction_inflight : out std_logic := '0';
      data_waitbus : out std_logic := '0';
      dma_bus_idle : out std_logic := '0'
   );
end entity;

architecture rtl of nds_nitro_arm9_adapter is
   signal nitro_save : nitro_arm9.pProc_bus_gba.proc_bus_gb_type;
   signal cpu_pc : std_logic_vector(31 downto 0);
   signal cpu_addr, cpu_wdata, cpu_rdata, cpu_lastread :
      std_logic_vector(31 downto 0);
   signal cpu_acc, cpu_lowbits : std_logic_vector(1 downto 0);
   signal cpu_rnw, cpu_ena, cpu_code, cpu_done : std_logic;
   signal cpu_retired, cpu_bus_idle, cpu_halt : std_logic;

   signal cp15_itcm_ena, cp15_itcm_load : std_logic;
   signal cp15_dtcm_ena, cp15_dtcm_load : std_logic;
   signal cp15_dtcm_base : std_logic_vector(31 downto 12);
   signal cp15_dtcm_size, cp15_itcm_size : std_logic_vector(4 downto 0);
   signal bus_cacheable_i, bus_cacheable_d : std_logic;
   signal cache_op_ena, cache_op_busy : std_logic;
   signal cache_op : std_logic_vector(3 downto 0);
   signal cache_op_addr : std_logic_vector(31 downto 0);

   signal itcm_addr : unsigned(14 downto 2);
   signal itcm_we : std_logic;
   signal itcm_be : std_logic_vector(3 downto 0);
   signal itcm_wdata, itcm_rdata : std_logic_vector(31 downto 0);
   signal dtcm_addr, dtcm_addr_b : unsigned(13 downto 2);
   signal dtcm_we_b : std_logic;
   signal dtcm_be_b : std_logic_vector(3 downto 0);
   signal dtcm_wdata_b, dtcm_rdata : std_logic_vector(31 downto 0);
   signal brom_addr : unsigned(14 downto 2);
   signal brom_data : std_logic_vector(31 downto 0);

   signal wsh_ena, wsh_rnw, vram_ena, vram_rnw : std_logic;
   signal wsh_addr : unsigned(14 downto 2);
   signal vram_addr : unsigned(23 downto 2);
   signal wsh_be, vram_be : std_logic_vector(3 downto 0);
   signal wsh_din, vram_din : std_logic_vector(31 downto 0);
   signal wsh_low, vram_low, io_low : std_logic_vector(1 downto 0);
   signal mr_ena, mr_rnw : std_logic;
   signal mr_addr : std_logic_vector(21 downto 2);
   signal mr_be : std_logic_vector(3 downto 0);
   signal mr_wdata : std_logic_vector(31 downto 0);
   signal mr_pair : std_logic;
   signal mr_done_i : std_logic := '0';
   signal mr_rdata, mr_rdata_hi : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal mr_single_active : std_logic := '0';
   signal io_bus : nitro_arm9.pProc_bus_gba.proc_bus_gb_type;
   signal cold_ena, cold_rnw : std_logic;
   signal cold_addr, cold_din : std_logic_vector(31 downto 0);
   signal cold_acc : std_logic_vector(1 downto 0);

   signal external_ena, external_rnw : std_logic;
   signal external_addr, external_wdata : std_logic_vector(31 downto 0);
   signal external_acc : std_logic_vector(1 downto 0);
   type pair_state_t is (PAIR_IDLE, PAIR_LOW_ISSUE, PAIR_LOW_WAIT,
                         PAIR_HIGH_ISSUE, PAIR_HIGH_WAIT, PAIR_RESPONSE);
   signal pair_state : pair_state_t := PAIR_IDLE;
   signal pair_low_addr, pair_high_addr : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pair_low_data, pair_high_data : std_logic_vector(31 downto 0) :=
      (others => '0');
   signal pair_request : std_logic;
   signal pair_owner_active : std_logic;
   signal single_request_active : std_logic;
   signal mr_write_acc : std_logic_vector(1 downto 0);
   signal mr_write_addr : std_logic_vector(31 downto 0);
   signal mr_write_data : std_logic_vector(31 downto 0);
   signal mr_base_addr : std_logic_vector(31 downto 0);

   signal halt_level_d : std_logic := '0';
   signal halt_pulse, unhalt_pulse : std_logic;
   signal request_code : std_logic := '0';
   signal instruction_active : std_logic := '0';
   signal admit_instruction, cpu_ce : std_logic;
   signal retire_pulse : std_logic := '0';
begin
   -- The boot sequencer drives the current package. Copy only the fields used
   -- by the Nitro preset-only savestate registers.
   nitro_save.Din <= savestate_bus.Din;
   nitro_save.Adr <= savestate_bus.Adr;
   nitro_save.rnw <= savestate_bus.rnw;
   nitro_save.ena <= savestate_bus.ena;
   nitro_save.acc <= savestate_bus.acc;
   nitro_save.bEna <= savestate_bus.bEna;
   nitro_save.rst <= savestate_bus.rst;

   halt_pulse <= halt_level and not halt_level_d;
   unhalt_pulse <= not halt_level and halt_level_d;

   -- Serialized fill keeps W_MAIN owned. The adapter then has one source at a
   -- time and only needs to split a pair into two launch pulses.
   pair_request <= '1' when pair_state = PAIR_LOW_ISSUE or
                            pair_state = PAIR_HIGH_ISSUE else '0';
   pair_owner_active <= '1' when pair_state /= PAIR_IDLE else '0';
   single_request_active <= mr_ena and not mr_pair;
   external_ena <= pair_request or single_request_active or
                   wsh_ena or vram_ena or
                   io_bus.ena or cold_ena;
   external_addr <= pair_low_addr when pair_state = PAIR_LOW_ISSUE else
                    pair_high_addr when pair_state = PAIR_HIGH_ISSUE else
                    mr_write_addr when single_request_active = '1' and
                       mr_rnw = '0' else
                    "0000001000" & mr_addr & "00"
                       when single_request_active = '1' else
                    std_logic_vector(to_unsigned(16#03000000#, 32) +
                       resize(unsigned(std_logic_vector(wsh_addr) & wsh_low),
                              32))
                       when wsh_ena = '1' else
                    x"06" & std_logic_vector(vram_addr) &
                       vram_low
                       when vram_ena = '1' else
                    x"0" & io_bus.Adr(27 downto 2) &
                       io_low when io_bus.ena = '1' else
                    cold_addr;
   external_rnw <= '1' when pair_request = '1' else
                   mr_rnw when single_request_active = '1' else
                   wsh_rnw when wsh_ena = '1' else
                   vram_rnw when vram_ena = '1' else
                   io_bus.rnw when io_bus.ena = '1' else
                   cold_rnw;
   external_acc <= "10" when pair_request = '1' else
                   mr_write_acc when single_request_active = '1' and
                       mr_rnw = '0' else
                   "10" when single_request_active = '1' else
                   cpu_acc when wsh_ena = '1' or vram_ena = '1' or
                       io_bus.ena = '1' else
                   cold_acc when cold_ena = '1' else cpu_acc;
   external_wdata <= mr_write_data when single_request_active = '1' else
                     cpu_wdata when wsh_ena = '1' or vram_ena = '1' or
                        io_bus.ena = '1' else
                     cold_din;

   -- Main-RAM writes arrive lane-placed from membus9. Reconstruct the raw CPU
   -- form expected by nds_cpu_ddram. Cache reads remain aligned words.
   mr_write_acc <= "00" when mr_be = "0001" or mr_be = "0010" or
                              mr_be = "0100" or mr_be = "1000" else
                   "01" when mr_be = "0011" or mr_be = "1100" else "10";
   mr_base_addr <= "0000001000" & mr_addr & "00";
   mr_write_addr <= mr_base_addr when mr_be = "0001" or
                                      mr_be = "0011" or mr_be = "1111" else
                    std_logic_vector(unsigned(mr_base_addr) + 1)
                       when mr_be = "0010" else
                    std_logic_vector(unsigned(mr_base_addr) + 2)
                       when mr_be = "0100" or mr_be = "1100" else
                    std_logic_vector(unsigned(mr_base_addr) + 3);
   mr_write_data <= x"000000" & mr_wdata(7 downto 0)
      when mr_be = "0001" else
                    x"000000" & mr_wdata(15 downto 8)
      when mr_be = "0010" else
                    x"000000" & mr_wdata(23 downto 16)
      when mr_be = "0100" else
                    x"000000" & mr_wdata(31 downto 24)
      when mr_be = "1000" else
                    x"0000" & mr_wdata(15 downto 0)
      when mr_be = "0011" else
                    x"0000" & mr_wdata(31 downto 16)
      when mr_be = "1100" else mr_wdata;

   address <= external_addr;
   read_not_write <= external_rnw;
   bus_access <= external_acc;
   write_data <= external_wdata;
   request <= external_ena and not reset;

   debug_pc <= cpu_pc;
   dtcm_region <= cp15_dtcm_base & x"000";
   dtcm_enable <= cp15_dtcm_ena;

   -- Keep the Stage-A scheduler contract. The memory island removes TCM and
   -- I-cache traffic from the cold boundary without changing ETW in this step.
   admit_instruction <= step_enable and not dma_pause and
      not instruction_active and
      (cpu_bus_idle or request_code) and not cpu_retired and
      not cpu_halt and not reset;
   cpu_ce <= admit_instruction or instruction_active;
   step_boundary <= not instruction_active and
      (cpu_bus_idle or request_code) and not cpu_retired;
   instruction_inflight <= instruction_active;
   data_waitbus <= instruction_active and not cpu_bus_idle and
      not request_code;
   -- A DMA grant is safe only after each serialized cache pair, main-RAM
   -- single request, and other exported request has drained.
   dma_bus_idle <= cpu_bus_idle when pair_state = PAIR_IDLE and
      mr_single_active = '0' and external_ena = '0' else '0';
   -- The donor CPU has no normalized cycle-report port. Keep the Stage-A
   -- one-unit scheduler placeholder. This default-off Stage-B path is not
   -- qualified for architectural timing or ETW results.
   cycles <= std_logic_vector(to_unsigned(1, cycles'length));
   cycles_valid <= retire_pulse;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            halt_level_d <= '0';
            request_code <= '0';
            instruction_active <= '0';
            retire_pulse <= '0';
         else
            halt_level_d <= halt_level;
            retire_pulse <= '0';
            if cpu_ena = '1' then
               request_code <= cpu_code;
            end if;
            if admit_instruction = '1' then
               instruction_active <= '1';
            end if;
            if instruction_active = '1' and cpu_retired = '1' then
               retire_pulse <= '1';
               instruction_active <= '0';
            end if;
         end if;
      end if;
   end process;

   -- Nitro requests an aligned 8-byte pair for each instruction-cache fill.
   -- r343 has a 32-bit ARM9 boundary, so issue two ordered word reads and
   -- release one membus completion only after both replies are captured.
   process(clk)
   begin
      if rising_edge(clk) then
         mr_done_i <= '0';
         if reset = '1' then
            pair_state <= PAIR_IDLE;
            mr_single_active <= '0';
            pair_low_data <= (others => '0');
            pair_high_data <= (others => '0');
         else
            if mr_single_active = '0' and mr_ena = '1' and mr_pair = '0' then
               mr_single_active <= '1';
            elsif mr_single_active = '1' and pair_owner_active = '0' and
                  done = '1' then
               mr_single_active <= '0';
            end if;
            case pair_state is
               when PAIR_IDLE =>
                  if mr_ena = '1' and mr_pair = '1' then
                     pair_low_addr <= "0000001000" & mr_addr(21 downto 3) &
                        '0' & "00";
                     pair_high_addr <= "0000001000" & mr_addr(21 downto 3) &
                        '1' & "00";
                     pair_state <= PAIR_LOW_ISSUE;
                  elsif mr_single_active = '1' and pair_owner_active = '0' and
                        done = '1' then
                     mr_rdata <= read_data;
                     mr_done_i <= '1';
                  end if;
               when PAIR_LOW_ISSUE =>
                  pair_state <= PAIR_LOW_WAIT;
               when PAIR_LOW_WAIT =>
                  if pair_owner_active = '1' and done = '1' then
                     pair_low_data <= read_data;
                     pair_state <= PAIR_HIGH_ISSUE;
                  end if;
               when PAIR_HIGH_ISSUE =>
                  pair_state <= PAIR_HIGH_WAIT;
               when PAIR_HIGH_WAIT =>
                  if pair_owner_active = '1' and done = '1' then
                     pair_high_data <= read_data;
                     pair_state <= PAIR_RESPONSE;
                  end if;
               when PAIR_RESPONSE =>
                  mr_rdata <= pair_low_data;
                  mr_rdata_hi <= pair_high_data;
                  mr_done_i <= '1';
                  if mr_ena = '0' then
                     pair_state <= PAIR_IDLE;
                  end if;
            end case;
         end if;
      end if;
   end process;

   cpu : entity nitro_arm9.nds_cpu9
      generic map (is_simu => '0', SS_PRESET_ONLY => '1')
      port map (
         clk => clk, ce => cpu_ce, reset => reset,
         error_cpu => open, dbg_pc => cpu_pc, dbg_r0 => open,
         dbg_lr => open, dbg_cpsr => open,
         dbg_regsel => (others => '0'), dbg_regval => open,
         savestate_bus => nitro_save, ss_wired_out => open,
         ss_wired_done => open,
         gb_bus_Adr => cpu_addr, gb_bus_rnw => cpu_rnw,
         gb_bus_ena => cpu_ena, gb_bus_seq => open,
         gb_bus_code => cpu_code, gb_bus_acc => cpu_acc,
         gb_bus_dout => cpu_wdata, gb_bus_din => cpu_rdata,
         gb_bus_done => cpu_done, gb_bus_lock => open,
         bus_lowbits => cpu_lowbits, dma_on => dma_pause,
         done => cpu_retired,
         CPU_bus_idle => cpu_bus_idle, PC_in_BIOS => open,
         cpu_halt => cpu_halt, lastread => cpu_lastread, jump_out => open,
         IRQ_in => irq, unhalt => unhalt_pulse, new_halt => halt_pulse,
         cp15_vector_hi => open, cp15_pu_enable => open,
         cp15_icache_ena => open, cp15_dcache_ena => open,
         cp15_itcm_ena => cp15_itcm_ena,
         cp15_itcm_load => cp15_itcm_load,
         cp15_dtcm_ena => cp15_dtcm_ena,
         cp15_dtcm_load => cp15_dtcm_load,
         cp15_dtcm_base => cp15_dtcm_base,
         cp15_dtcm_size => cp15_dtcm_size,
         cp15_itcm_size => cp15_itcm_size,
         bus_cacheable_i => bus_cacheable_i,
         bus_cacheable_d => bus_cacheable_d,
         cache_op_ena => cache_op_ena, cache_op => cache_op,
         cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy
      );

   membus : entity nitro_arm9.nds_membus9
      generic map (is_simu => '0', cold_external_enable => true)
      port map (
         clk => clk, reset => reset,
         itcm_ena => cp15_itcm_ena, itcm_load => cp15_itcm_load,
         itcm_size => cp15_itcm_size,
         dtcm_ena => cp15_dtcm_ena, dtcm_load => cp15_dtcm_load,
         dtcm_base => cp15_dtcm_base, dtcm_size => cp15_dtcm_size,
         bus_cacheable_i => bus_cacheable_i,
         -- Stage B has no D-cache. Every data access bypasses it.
         bus_cacheable_d => '0',
         cache_op_ena => cache_op_ena, cache_op => cache_op,
         cache_op_addr => cache_op_addr, cache_op_busy => cache_op_busy,
         dma_bus => '0',
         cpu_adr => cpu_addr, cpu_rnw => cpu_rnw, cpu_ena => cpu_ena,
         cpu_code => cpu_code, cpu_acc => cpu_acc, cpu_dout => cpu_wdata,
         cpu_lowbits => cpu_lowbits, cpu_lastread => cpu_lastread,
         cpu_din => cpu_rdata, cpu_done => cpu_done,
         itcm_addr => itcm_addr, itcm_we => itcm_we, itcm_be => itcm_be,
         itcm_writedata => itcm_wdata, itcm_readdata => itcm_rdata,
         dtcm_addr => dtcm_addr, dtcm_readdata => dtcm_rdata,
         dtcm_addr_b => dtcm_addr_b, dtcm_we_b => dtcm_we_b,
         dtcm_be_b => dtcm_be_b, dtcm_writedata_b => dtcm_wdata_b,
         brom_addr => brom_addr, brom_data => brom_data,
         wsh_ena => wsh_ena, wsh_rnw => wsh_rnw, wsh_addr => wsh_addr,
         wsh_be => wsh_be, wsh_din => wsh_din,
         wsh_low => wsh_low,
         wsh_dout => read_data, wsh_done => done, wsh_mapped => '1',
         vram_ena => vram_ena, vram_rnw => vram_rnw,
         vram_addr => vram_addr, vram_be => vram_be, vram_din => vram_din,
         vram_low => vram_low,
         vram_dout => read_data, vram_done => done,
         pal_we => open, pal_addr => open, pal_din => open, pal_be => open,
         oam_we => open, oam_addr => open, oam_din => open, oam_be => open,
         mr_ena => mr_ena, mr_rnw => mr_rnw, mr_addr => mr_addr,
         mr_be => mr_be, mr_writedata => mr_wdata,
         mr_done => mr_done_i, mr_readdata => mr_rdata,
         -- One pair fill becomes two ordered r343 word requests above.
         mr_pair => mr_pair, mr_readdata_hi => mr_rdata_hi,
         io_ce_next => '1', io_bus => io_bus,
         io_low => io_low,
         io_wired_out => read_data, io_wired_done => done,
         cold_ena => cold_ena, cold_rnw => cold_rnw,
         cold_addr => cold_addr, cold_acc => cold_acc,
         cold_din => cold_din, cold_dout => read_data, cold_done => done,
         dbg_mb => open, dbg_cache => open
      );

   bios : entity nitro_arm9.nds_bios9
      generic map (is_simu => '0', use_cyclone5_primitive => '1')
      port map (
         clk => clk, brom_addr => brom_addr, brom_data => brom_data,
         load_addr => (others => '0'), load_data => (others => '0'),
         load_be => (others => '0'), load_we => '0', load_done => '0'
      );

   itcm : entity MEM.SyncRamDualByteEnable
      generic map (
         is_simu => '0', is_cyclone5 => '1', BYTE_WIDTH => 8,
         ADDR_WIDTH => 13, BYTES => 4)
      port map (
         clk => clk, ce_a => '1', addr_a => to_integer(itcm_addr),
         datain_a0 => itcm_wdata(7 downto 0),
         datain_a1 => itcm_wdata(15 downto 8),
         datain_a2 => itcm_wdata(23 downto 16),
         datain_a3 => itcm_wdata(31 downto 24), dataout_a => itcm_rdata,
         we_a => itcm_we, be_a => itcm_be, ce_b => '0', addr_b => 0,
         datain_b0 => x"00", datain_b1 => x"00",
         datain_b2 => x"00", datain_b3 => x"00", dataout_b => open,
         we_b => '0', be_b => "0000"
      );

   dtcm : entity MEM.SyncRamDualByteEnable
      generic map (
         is_simu => '0', is_cyclone5 => '1', BYTE_WIDTH => 8,
         ADDR_WIDTH => 12, BYTES => 4)
      port map (
         clk => clk, ce_a => '1', addr_a => to_integer(dtcm_addr),
         datain_a0 => x"00", datain_a1 => x"00",
         datain_a2 => x"00", datain_a3 => x"00", dataout_a => dtcm_rdata,
         we_a => '0', be_a => "0000", ce_b => '1',
         addr_b => to_integer(dtcm_addr_b),
         datain_b0 => dtcm_wdata_b(7 downto 0),
         datain_b1 => dtcm_wdata_b(15 downto 8),
         datain_b2 => dtcm_wdata_b(23 downto 16),
         datain_b3 => dtcm_wdata_b(31 downto 24), dataout_b => open,
         we_b => dtcm_we_b, be_b => dtcm_be_b
      );
end architecture;
