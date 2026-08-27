-- SPDX-License-Identifier: GPL-3.0-or-later
-- SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
-- ARM946E-S for the NDS (roadmap M3): fork of the vendored gba_cpu (ARM7TDMI).
-- Additions over the GBA core:
--   * ARMv5TE instructions: CLZ, QADD/QSUB/QDADD/QDSUB (Q flag), the SMULxy/
--     SMLAxy/SMULWy/SMLAWy/SMLALxy DSP multiplies, BLX (imm + reg, ARM and
--     Thumb), LDRD/STRD, PLD (executes as nop)
--   * v5 interworking: LDR/LDM to PC switch ARM/Thumb from bit 0
--   * CP15 via MCR/MRC: ID regs, control reg (high vectors, TCM/cache
--     enables), PU region regs (stored), cache ops (accepted; the cache
--     hierarchy itself arrives with the memory system), DTCM base/size and
--     ITCM size, wait-for-interrupt (c7,c0,4 halts until IRQ)
--   * exception vectors at 0xFFFF0000 when control bit 13 is set
-- The TCMs themselves live in the ARM9 bus decoder (nds_membus9), configured
-- from the cp15_* output ports here.
-- Savestate shadow registers reuse the GBA addresses — each CPU instance gets
-- its own savestate_bus, so the address spaces do not collide.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use STD.textio.all;

use work.pexport.all;
use work.pProc_bus_gba.all;
use work.pReg_savestates.all;

entity nds_cpu9 is
   generic
   (
      is_simu : std_logic;
      -- See the "savestates" block below. '1' builds only the seven savestate
      -- registers nds_top's boot preset writes; '0' restores the full bus.
      SS_PRESET_ONLY : std_logic := '1'
   );
   port 
   (
      clk              : in    std_logic;  
      ce               : in    std_logic;
      reset            : in    std_logic;
      
-- synthesis translate_off
      cpu_export_done  : out std_logic := '0'; 
      cpu_export       : out cpu_export_type := export_init;
-- synthesis translate_on 
      
      error_cpu        : out   std_logic := '0';
      dbg_pc           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_r0           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_lr           : out   std_logic_vector(31 downto 0) := (others => '0');
      dbg_cpsr         : out   std_logic_vector(31 downto 0) := (others => '0');
      -- Full architectural register read-back for nds_debug: 0..15 select
      -- r0..r15 in the CPU's current mode, 16 selects CPSR.
      dbg_regsel       : in    unsigned(4 downto 0) := (others => '0');
      dbg_regval       : out   std_logic_vector(31 downto 0) := (others => '0');
      
      savestate_bus    : in    proc_bus_gb_type;
      ss_wired_out     : out   std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      ss_wired_done    : out   std_logic;
      
      gb_bus_Adr       : out   std_logic_vector(31 downto 0);
      gb_bus_rnw       : out   std_logic;
      gb_bus_ena       : out   std_logic;
      gb_bus_seq       : out   std_logic;
      gb_bus_code      : out   std_logic;
      gb_bus_acc       : out   std_logic_vector(1 downto 0);
      gb_bus_dout      : out   std_logic_vector(31 downto 0);
      gb_bus_din       : in    std_logic_vector(31 downto 0);
      gb_bus_done      : in    std_logic;
      gb_bus_lock      : out   std_logic := '0';
        
      bus_lowbits      : out   std_logic_vector(1 downto 0) := "00";
        
      dma_on           : in    std_logic;
      done             : buffer std_logic := '0';
      CPU_bus_idle     : out   std_logic;
      PC_in_BIOS       : out   std_logic;
      cpu_halt         : out   std_logic;
      lastread         : out   std_logic_vector(31 downto 0);
      jump_out         : out   std_logic;
      
      IRQ_in           : in    std_logic;
      unhalt           : in    std_logic;
      new_halt         : in    std_logic;

      -- CP15 configuration to the bus decoder / memory system
      cp15_vector_hi   : out   std_logic;                      -- control bit 13
      cp15_pu_enable   : out   std_logic;                      -- control bit 0
      cp15_icache_ena  : out   std_logic;                      -- control bit 12
      cp15_dcache_ena  : out   std_logic;                      -- control bit 2
      cp15_itcm_ena    : out   std_logic;                      -- control bit 18
      cp15_itcm_load   : out   std_logic;                      -- control bit 19
      cp15_dtcm_ena    : out   std_logic;                      -- control bit 16
      cp15_dtcm_load   : out   std_logic;                      -- control bit 17
      cp15_dtcm_base   : out   std_logic_vector(31 downto 12); -- region base
      cp15_dtcm_size   : out   std_logic_vector(4 downto 0);   -- 512B << N
      cp15_itcm_size   : out   std_logic_vector(4 downto 0);

      -- PU cachability of the current bus address (combinational lookup on
      -- gb_bus_Adr; qualified with the control-reg cache enables)
      bus_cacheable_i  : out   std_logic;
      bus_cacheable_d  : out   std_logic;

      -- cache maintenance ops (MCR c7): one-cycle ena pulse, the CPU stalls
      -- until cache_op_busy has fallen again. op encoding:
      --   0000 inv I all   0001 inv I line MVA
      --   0010 inv D all   0011 inv D line MVA   0100 inv D line idx
      --   0101 clean D MVA 0110 clean D idx
      --   0111 clean+inv D MVA                   1000 clean+inv D idx
      cache_op_ena     : out   std_logic := '0';
      cache_op         : out   std_logic_vector(3 downto 0) := (others => '0');
      cache_op_addr    : out   std_logic_vector(31 downto 0) := (others => '0');
      cache_op_busy    : in    std_logic
   );
end entity;

architecture arch of nds_cpu9 is

   -- ####################################
   -- ARM processor regs and states 
   -- ####################################
    
   constant CPUMODE_USER       : std_logic_vector(3 downto 0) := x"0";
   constant CPUMODE_FIQ        : std_logic_vector(3 downto 0) := x"1";
   constant CPUMODE_IRQ        : std_logic_vector(3 downto 0) := x"2";
   constant CPUMODE_SUPERVISOR : std_logic_vector(3 downto 0) := x"3";
   constant CPUMODE_ABORT      : std_logic_vector(3 downto 0) := x"7";
   constant CPUMODE_UNDEFINED  : std_logic_vector(3 downto 0) := x"B";
   constant CPUMODE_SYSTEM     : std_logic_vector(3 downto 0) := x"F";
   
   signal thumbmode        : std_logic := '0';
         
   signal IRQ_disable      : std_logic := '1';
   signal FIQ_disable      : std_logic := '1';
   
   signal Flag_Zero        : std_logic := '0';
   signal Flag_Carry       : std_logic := '0';
   signal Flag_Negative    : std_logic := '0';
   signal Flag_V_Overflow  : std_logic := '0';
   signal Flag_Q_Sticky    : std_logic := '0';   -- v5TE saturation flag, CPSR(27)

   -- ############# CP15 ##############
   -- control register: bits 3..6 read as 1 on the 946E-S
   -- Power-up values must match the synchronous reset below: see the comment
   -- there. These are the post-ARM9-BIOS state that HLE direct boot skips.
   signal cp15_control     : std_logic_vector(31 downto 0) := x"00012078";
   signal cp15_dtcm_reg    : std_logic_vector(31 downto 0) := x"0300000A"; -- c9,c1,0
   signal cp15_itcm_reg    : std_logic_vector(31 downto 0) := x"00000020"; -- c9,c1,1
   type t_cp15_regions is array (0 to 7) of std_logic_vector(31 downto 0);
   type t_cp15_masks   is array (0 to 7) of unsigned(31 downto 12);
   -- per-region "bits above the size code" mask, derived from the region
   -- registers only so it stays off the address path (see the PU compare below)
   signal cp15_pu_mask : t_cp15_masks;
   signal cp15_pu_region   : t_cp15_regions :=                                -- c6,cN,0
   (
      0 => x"04000033", 1 => x"0200002B", 2 => x"00000000", 3 => x"08000035",
      4 => x"0300001B", 5 => x"00000000", 6 => x"FFFF001D", 7 => x"027FF017"
   );
   signal cp15_pu_dcache   : std_logic_vector(31 downto 0) := x"00000042"; -- c2,c0,0
   signal cp15_pu_icache   : std_logic_vector(31 downto 0) := x"00000042"; -- c2,c0,1
   signal cp15_pu_wbuf     : std_logic_vector(31 downto 0) := x"00000002"; -- c3,c0,0
   signal cp15_pu_dperm    : std_logic_vector(31 downto 0) := x"15111011"; -- c5,c0,2 (extended)
   signal cp15_pu_iperm    : std_logic_vector(31 downto 0) := x"05100011"; -- c5,c0,3 (extended)
   signal cp15_dcache_lock : std_logic_vector(31 downto 0) := (others => '0'); -- c9,c0,0
   signal cp15_icache_lock : std_logic_vector(31 downto 0) := (others => '0'); -- c9,c0,1
   signal cp15_trace_pid   : std_logic_vector(31 downto 0) := (others => '0'); -- c13 (stored)

   signal execute_wfi      : std_logic;   -- MCR c7,c0,4: halt until IRQ
   signal execute_cp15_cacheop : std_logic; -- MCR c7 op handled by nds_cache9
   
   signal cpu_mode         : std_logic_vector(3 downto 0) := CPUMODE_SUPERVISOR;
   
   signal CPSR             : unsigned(31 downto 0);
   signal SPSR             : unsigned(31 downto 0);

   type t_regs is array(0 to 15) of unsigned(31 downto 0);
   signal regs : t_regs := (others => (others => '0'));
   
   signal regs_0_8  : unsigned(31 downto 0) := (others => '0');
   signal regs_0_9  : unsigned(31 downto 0) := (others => '0');
   signal regs_0_10 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_11 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_12 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_0_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_8  : unsigned(31 downto 0) := (others => '0');
   signal regs_1_9  : unsigned(31 downto 0) := (others => '0');
   signal regs_1_10 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_11 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_12 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_1_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_2_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_3_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_4_17 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_13 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_14 : unsigned(31 downto 0) := (others => '0');
   signal regs_5_17 : unsigned(31 downto 0) := (others => '0');
       
   -- ############# Bus ##############
   type tbusState is
   (
      BUSSTATE_IDLE,
      BUSSTATE_WAITFETCH,
      BUSSTATE_WAITDATA
   );
     
   signal busState : tbusState := BUSSTATE_IDLE;
   
   signal bus_accessFetch     : std_logic;
   signal bus_AddrFetch       : unsigned(31 downto 0);
   
   signal gb_bus_save         : std_logic;
   signal gb_bus_saved        : std_logic := '0';
   signal gb_bus_saved_st1    : std_logic := '0';
   signal gb_bus_saved_Adr    : std_logic_vector(31 downto 0);
   signal gb_bus_saved_rnw    : std_logic;
   signal gb_bus_saved_seq    : std_logic;
   signal gb_bus_saved_acc    : std_logic_vector(1 downto 0);
   signal gb_bus_saved_dout   : std_logic_vector(31 downto 0);
   signal gb_bus_lock_active  : std_logic := '0';
   
   signal dma_on_1            : std_logic := '0';
   
   -- ############# Fetch ##############
   signal fetch_done       : std_logic;
   signal fetch_PC         : unsigned(31 downto 0) := (others => '0');
   signal fetch_data       : std_logic_vector(31 downto 0) := (others => '0');
   signal fetch_ready      : std_logic := '0';
   signal fetch_first      : std_logic := '0';
   
   -- ############# Decode ##############
   type tFunctions is
   (
      -- arm/combined
      branch_and_exchange,
      data_processing,
      single_data_swap,
      multiply_long,
      multiply,
      halfword_data_transfer_regoffset,
      halfword_data_transfer_immoffset,
      single_data_transfer,
      block_data_transfer,
      branch,
      software_interrupt,
      -- thumb
      long_branch_with_link,
      -- v5TE additions
      v5_misc,          -- CLZ / QADD family / DSP multiplies (sub-decoded)
      coprocessor_op,   -- MCR/MRC p15
      v5_nop            -- PLD, CDP, LDC/STC, MCR2/MRC2: execute as nop
   );

   type tFunctions_detail is
   (
      alu_and,
      alu_xor,
      alu_sub,
      alu_add,
      alu_add_withcarry,
      alu_sub_withcarry,
      alu_or,
      alu_mov,
      alu_and_not,
      alu_mov_not,
      mulboth,
      data_processing_MRS,
      data_processing_MSR,
      branch_all,
      data_read,
      data_write,
      block_read,
      block_write,
      software_interrupt_detail,
      IRQ,
      -- v5TE additions
      alu_clz,
      sat_arith,
      mul_dsp,
      cp15_op,
      nop_detail
   );
   
   type tdatareceivetype is
   (
      RECEIVETYPE_BYTE,
      RECEIVETYPE_DWORD,
      RECEIVETYPE_WORD,
      RECEIVETYPE_SIGNEDBYTE,
      RECEIVETYPE_SIGNEDWORD
   );
   
   signal decode_data                     : std_logic_vector(31 downto 0);
   signal decode_condition                : std_logic_vector(3 downto 0);
   
   signal decode_ready                    : std_logic := '0';     
   signal decode_halt                     : std_logic := '0';        
   signal decode_unhalt                   : std_logic := '0';     
   signal decode_PC                       : unsigned(31 downto 0) := (others => '0');
   signal decode_data_1                   : std_logic_vector(31 downto 0) := (others => '0');
   signal decode_functions_detail         : tFunctions_detail;
   signal decode_datareceivetype          : tdatareceivetype;
   signal decode_clearbit1                : std_logic := '0';
   signal decode_rdest                    : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_rdest_save               : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_Rn_op1                   : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_Rn_op1_save              : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_RM_op2                   : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_alu_use_immi             : std_logic := '0';
   signal decode_alu_use_shift            : std_logic := '0';
   signal decode_immidiate                : unsigned(31 downto 0) := (others => '0');
   signal decode_shift_regbased           : std_logic;
   signal decode_shift_mode               : std_logic_vector(1 downto 0);
   signal decode_shift_amount             : integer range 0 to 255;
   signal decode_shift_RRX                : std_logic;
   signal decode_shiftcarry               : std_logic := '0';
   signal decode_useoldcarry              : std_logic := '0';
   signal decode_updateflags              : std_logic := '0';
   signal decode_mul_signed               : std_logic := '0';
   signal decode_mul_useadd               : std_logic := '0';
   signal decode_mul_long                 : std_logic := '0';
   signal decode_writeback                : std_logic := '0';
   signal decode_switch_op                : std_logic := '0';
   signal decode_set_thumbmode            : std_logic := '0';
   signal decode_branch_usereg            : std_logic := '0';
   signal decode_branch_link              : std_logic := '0';
   signal decode_branch_long              : std_logic := '0';
   signal decode_branch_immi              : signed(25 downto 0) := (others => '0');
   signal decode_datatransfer_type        : std_logic_vector(1 downto 0) := (others => '0');
   signal decode_datatransfer_preadd      : std_logic := '0';
   signal decode_datatransfer_addup       : std_logic := '0';
   signal decode_datatransfer_writeback   : std_logic := '0';
   signal decode_datatransfer_addvalue    : unsigned(11 downto 0)  := (others => '0');
   signal decode_datatransfer_shiftval    : std_logic := '0';
   signal decode_datatransfer_regoffset   : std_logic := '0';
   signal decode_datatransfer_swap        : std_logic := '0';
   signal decode_block_usermoderegs       : std_logic := '0';
   signal decode_block_switchmode         : std_logic := '0';
   signal decode_block_addrmod            : integer range -64 to 64 := 0;
   signal decode_block_endmod             : integer range -64 to 64 := 0;
   signal decode_block_addrmod_baseRlist  : integer range -64 to 64 := 0;
   signal decode_block_reglist            : std_logic_vector(15 downto 0) := (others => '0');
   signal decode_block_emptylist          : std_logic := '0';
   signal decode_psr_with_spsr            : std_logic := '0';
   signal decode_leaveirp                 : std_logic := '0';

   -- v5TE decode outputs
   signal decode_sat_sub                  : std_logic := '0';
   signal decode_sat_double               : std_logic := '0';
   signal decode_dsp_x                    : std_logic := '0';
   signal decode_dsp_y                    : std_logic := '0';
   signal decode_dsp_acc                  : std_logic := '0';
   signal decode_dsp_long                 : std_logic := '0';
   signal decode_dsp_word                 : std_logic := '0';
   signal decode_dsp_acchi                : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_mrc                 : std_logic := '0';
   signal decode_cp15_crn                 : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_crm                 : std_logic_vector(3 downto 0) := (others => '0');
   signal decode_cp15_op2                 : std_logic_vector(2 downto 0) := (others => '0');
   signal decode_datatransfer_double      : std_logic := '0';
   signal decode_branch_forcethumb        : std_logic := '0';
   signal decode_branch_forcearm          : std_logic := '0';
   
   -- ############# Execute ##############
   signal execute_op1                     : unsigned(31 downto 0);
   signal execute_op2                     : unsigned(31 downto 0);
   signal execute_opDest                  : unsigned(31 downto 0);
               
   signal shiftervalue                    : unsigned(31 downto 0);
   signal shiftresult                     : unsigned(31 downto 0);
   signal shiftercarry                    : std_logic;
                                          
   -- single-rotator shifter control (all register-derived - see the shifter)
   type t_shfill is (FILL_ZERO, FILL_SIGN, FILL_CARRY);
   type t_shcsel is (CSEL_ZERO, CSEL_CARRY, CSEL_VALUE);
   signal sh_rot                          : integer range 0 to 31;
   signal sh_keep                         : std_logic_vector(31 downto 0);
   signal sh_fill                         : t_shfill;
   signal sh_cidx                         : integer range 0 to 31;
   signal sh_csel                         : t_shcsel;
   signal sh_rotv                         : unsigned(31 downto 0);
   signal sh_fillb                        : std_logic;


   signal alu_op1                         : unsigned(31 downto 0);
   signal alu_op2                         : unsigned(31 downto 0);
   signal alu_result                      : unsigned(31 downto 0);
   signal alu_result_add                  : unsigned(32 downto 0);
   signal alu_shiftercarry                : std_logic;
   signal alu_wait_shift                  : std_logic := '0';
   signal execute_cacheop_wait            : std_logic := '0';
   
   signal execute_flag_Carry              : std_logic;
   signal execute_flag_Zero               : std_logic;
   signal execute_flag_Negative           : std_logic;
   signal execute_flag_V_Overflow         : std_logic;
   
   signal execute_writeback               : std_logic;
   signal execute_writedata               : unsigned(31 downto 0);
   signal execute_writereg                : unsigned(3 downto 0);
   
   signal execute_branch                  : std_logic;
   signal execute_nextIsthumb             : std_logic;
   signal execute_branchPC                : unsigned(31 downto 0);
   signal execute_branchPC_masked         : unsigned(31 downto 0);
   -- PC-write fetch address, muxed straight into gb_bus_Adr (see there)
   signal pcwrite_fetch                   : std_logic;
   signal pcwrite_Addr                    : unsigned(31 downto 0);
   signal bus_AddrFetch_eff               : unsigned(31 downto 0);
   signal adr_early                       : std_logic_vector(31 downto 0);
   signal adr_is_pcw                      : std_logic;
               
   signal execute_stall                   : std_logic := '0';
   signal execute_done                    : std_logic;
   signal execute_now                     : std_logic;
   signal execute_skip                    : std_logic;


   type texecute_MUL_State is
   (
      MUL_IDLE,
      MUL_MUL,
      MUL_ADD,
      MUL_STOREHI,
      MUL_DSP_ACC,   -- v5TE DSP multiply: accumulate / writeback beat
      MUL_DSP_ACCHI  -- v5TE SMLAL<x><y>: high-word accumulate beat
   );
   signal execute_MUL_State : texecute_MUL_State := MUL_IDLE;
   signal execute_mul_opaddlow            : unsigned(31 downto 0) := (others => '0');
   signal execute_mul_opaddhigh           : unsigned(31 downto 0) := (others => '0');
   signal execute_mul_result              : unsigned(63 downto 0) := (others => '0');
   signal execute_mul_wait                : integer range 0 to 3 := 0;

   type texecute_RW_State is
   (
      DATARW_IDLE,
      DATARW_READSTART,
      DATARW_READWAIT,
      DATARW_READWAITDMA,
      DATARW_WRITE,
      DATARW_SWAPWRITE,
      DATARW_SWAPWAIT,
      DATARW_BLOCKREAD,
      DATARW_BLOCKWRITE,
      DATARW_BLOCKSWITCH,  -- ldm^ with pc: CPSR := SPSR + bank swap, one cycle after base writeback
      DATARW_READSTART_D2, -- v5TE LDRD: second word
      DATARW_WRITE_D2      -- v5TE STRD: second word
   );
   signal execute_RW_State : texecute_RW_State := DATARW_IDLE;
   signal execute_RW_data                 : std_logic_vector(31 downto 0);
   signal execute_RW_addr                 : unsigned(31 downto 0);
   signal execute_RW_addr_last            : unsigned(31 downto 0);
   signal execute_RW_rnw                  : std_logic;
   signal execute_RW_acc                  : std_logic_vector(1 downto 0);
   signal execute_RW_ena                  : std_logic;
   signal execute_busaddress              : unsigned(31 downto 0);
   signal execute_busaddmod               : unsigned(31 downto 0);
   signal execute_RW_dataRead             : std_logic_vector(31 downto 0);
   signal execute_RW_WBaddr               : unsigned(31 downto 0) := (others => '0');
   
   signal execute_blockRW_addr            : unsigned(31 downto 0) := (others => '0');
   signal execute_blockRW_writereg        : unsigned(3 downto 0) := (others => '0');
   signal execute_blockRW_last            : std_logic;
   signal execute_blockRW_endaddr         : unsigned(31 downto 0) := (others => '0');
   
   signal execute_msr_fetchvalue          : unsigned(31 downto 0);
   signal execute_msr_writevalue          : unsigned(31 downto 0);
   signal execute_msr_setvalue            : unsigned(31 downto 0);
   signal execute_msr_setvalue_ena        : std_logic;
   
   signal execute_switchmode_now          : std_logic;
   signal execute_switchmode_state        : std_logic;
   signal execute_switchmode_val          : std_logic_vector(3 downto 0);
   signal execute_switchmode_new          : std_logic_vector(3 downto 0);

   -- v5TE execute helpers
   signal exception_base                  : unsigned(31 downto 0);
   signal execute_clz_result              : unsigned(31 downto 0);
   signal execute_sat_result              : unsigned(31 downto 0);
   signal execute_sat_qset                : std_logic;
   signal execute_dsp_sum                 : unsigned(31 downto 0);
   signal execute_dsp_qset                : std_logic;
   signal execute_dsp_carry               : std_logic := '0';
   signal cp15_rdata                      : std_logic_vector(31 downto 0);
   
   -- savestates
   signal SAVESTATE_PC_in  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_PC_out : std_logic_vector(31 downto 0) := (others => '0');
   
   type t_regs_slv is array(0 to 17) of std_logic_vector(31 downto 0);
   signal SAVESTATE_REGS : t_regs_slv := (others => (others => '0'));
   
   type t_ss_wired_or is array(0 to 46) of std_logic_vector(31 downto 0);
   signal save_wired_or   : t_ss_wired_or;   
   signal save_wired_done : unsigned(0 to 46);
   
   signal SAVESTATE_REGS_0_8  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_9  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_10 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_11 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_12 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_0_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_8  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_9  : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_10 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_11 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_12 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_1_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_2_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_3_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_4_17 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_13 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_14 : std_logic_vector(31 downto 0) := (others => '0');
   signal SAVESTATE_REGS_5_17 : std_logic_vector(31 downto 0) := (others => '0');
   
   signal SAVESTATE_HALT            : std_logic;
   signal SAVESTATE_Flag_Zero       : std_logic;
   signal SAVESTATE_Flag_Carry      : std_logic;
   signal SAVESTATE_Flag_Negative   : std_logic;
   signal SAVESTATE_Flag_V_Overflow : std_logic;
   signal SAVESTATE_thumbmode       : std_logic;
   signal SAVESTATE_cpu_mode        : std_logic_vector(3 downto 0);
   signal SAVESTATE_IRQ_disable     : std_logic;
   signal SAVESTATE_FIQ_disable     : std_logic;
   
   signal SAVESTATE_mixed_in        : std_logic_vector(11 downto 0);
   signal SAVESTATE_mixed_out       : std_logic_vector(11 downto 0);
   
-- synthesis translate_off
   signal decode_opcode_export  : std_logic_vector(31 downto 0) := (others => '0');
   signal execute_opcode_export : std_logic_vector(31 downto 0) := (others => '0');
-- synthesis translate_on  
     
begin  

   -- Synthesizable one-wire-bundle tap for temporary live-hardware
   -- diagnosis. Unlike cpu_export, this remains present when is_simu='0'.
   dbg_pc <= std_logic_vector(regs(15));
   dbg_r0 <= std_logic_vector(regs(0));
   dbg_lr <= std_logic_vector(regs(14));
   dbg_cpsr <= std_logic_vector(CPSR);
   -- regsel(4) set selects CPSR, otherwise the low four bits index the visible
   -- register file. Cheaper than an equality compare against 16.
   dbg_regval <= std_logic_vector(CPSR) when dbg_regsel(4) = '1' else
                 std_logic_vector(regs(to_integer(dbg_regsel(3 downto 0))));
   -- Assert only for the two data-bus transfers belonging to SWP. Decode may
   -- advance to SWP while the preceding load is still in flight, so the raw
   -- decode bit is deliberately not exposed as the bus lock.
   gb_bus_lock <= gb_bus_lock_active or
                  (execute_RW_ena and decode_datatransfer_swap);

   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            gb_bus_lock_active <= '0';
         elsif (ce = '1') then
            if (execute_RW_ena = '1' and decode_datatransfer_swap = '1') then
               gb_bus_lock_active <= '1';
            elsif (gb_bus_lock_active = '1' and gb_bus_done = '1' and
                   execute_RW_State = DATARW_SWAPWRITE) then
               gb_bus_lock_active <= '0';
            end if;
         end if;
      end if;
   end process;

   CPSR(3 downto 0)  <= unsigned(cpu_mode);
   CPSR(4)           <= '1';
   CPSR(5)           <= thumbmode;
   CPSR(6)           <= FIQ_disable;
   CPSR(7)           <= IRQ_disable;
   CPSR(26 downto 8) <= (others => '0');
   CPSR(27)          <= Flag_Q_Sticky;
   CPSR(28)          <= Flag_V_Overflow;
   CPSR(29)          <= Flag_Carry;
   CPSR(30)          <= Flag_Zero;
   CPSR(31)          <= Flag_Negative;
   
   SPSR <= regs_1_17 when (cpu_mode = CPUMODE_FIQ) else
           regs_2_17 when (cpu_mode = CPUMODE_IRQ) else
           regs_3_17 when (cpu_mode = CPUMODE_SUPERVISOR) else
           regs_4_17 when (cpu_mode = CPUMODE_ABORT) else
           regs_5_17 when (cpu_mode = CPUMODE_UNDEFINED) else
           CPSR;
   
   
   PC_in_BIOS <= '1' when bus_AddrFetch(31 downto 16) = x"FFFF" else '0';

   cpu_halt   <= decode_halt;

   -- CP15 configuration exports
   cp15_vector_hi  <= cp15_control(13);
   cp15_pu_enable  <= cp15_control(0);
   cp15_icache_ena <= cp15_control(12);
   cp15_dcache_ena <= cp15_control(2);
   cp15_itcm_ena   <= cp15_control(18);
   cp15_itcm_load  <= cp15_control(19);
   cp15_dtcm_ena   <= cp15_control(16);
   cp15_dtcm_load  <= cp15_control(17);
   cp15_dtcm_base  <= cp15_dtcm_reg(31 downto 12);
   cp15_dtcm_size  <= cp15_dtcm_reg(5 downto 1);
   cp15_itcm_size  <= cp15_itcm_reg(5 downto 1);

   -- PU cachability lookup for the current bus address. Highest-numbered
   -- matching region wins; PU disabled or no region hit = uncachable.
   -- Region reg: bit 0 enable, bits 5:1 size code (2^(N+1) bytes), 31:12 base.
   -- The region-size compare used to be `shift_right(a xor base, sz+1) = 0`,
   -- which put the *address* through eight 32-bit variable barrel shifters. That
   -- cost ~5.5 ns and made this the second-biggest term on the worst clk_sys
   -- path; 36 of the 50 worst paths in a 98% build ended at the flop this feeds
   -- (nds_membus9|creq_cacheable), 16 of them through these shifters.
   --
   -- shift_right(x, sz+1) = 0  <->  bits [31:sz+1] of x are all zero
   --                           <->  (x and mask) = 0, mask(i)='1' iff i > sz
   -- The mask depends only on cp15_pu_region, which is a register, so building
   -- it here keeps the shift entirely off the address path: the address now sees
   -- just xor -> and -> zero-detect. Identical Boolean function, same cycle, and
   -- it replaces eight barrel shifters with eight decoders (frees ALMs, which is
   -- the binding constraint on this design). sz=31 gives an all-zero mask, which
   -- matches shift_right(x,32)=0 always being true.
   -- The compare runs on bits 31:12 only. The mask is `i > sz` and a region
   -- register can only express a 4 KB-aligned base, so for every size code the
   -- ARM946E-S allows (4 KB is its minimum region, sz = 11) the low twelve mask
   -- bits are already zero and those address bits were being compared against
   -- nothing. Below that they made a sub-4 KB region match only its first byte;
   -- melonDS resolves the PU into a per-4 KB-page table (PU_Map[addr >> 12]),
   -- so treating an illegal sub-page region as a page is also the oracle's
   -- answer. What it buys is 12 of 32 bits off the widest layer of a compare
   -- that is 58% interconnect on the worst path.
   process (all)
      variable sz : integer range 0 to 31;
   begin
      for r in 0 to 7 loop
         sz := to_integer(unsigned(cp15_pu_region(r)(5 downto 1)));
         for i in 12 to 31 loop
            if (i > sz) then cp15_pu_mask(r)(i) <= '1';
            else             cp15_pu_mask(r)(i) <= '0';
            end if;
         end loop;
      end loop;
   end process;

   process (all)
      variable a : unsigned(31 downto 12);
   begin
      bus_cacheable_i <= '0';
      bus_cacheable_d <= '0';
      a := unsigned(gb_bus_Adr(31 downto 12));
      if (cp15_control(0) = '1') then
         for r in 0 to 7 loop
            if (cp15_pu_region(r)(0) = '1') then
               if (((a xor unsigned(cp15_pu_region(r)(31 downto 12)))
                    and cp15_pu_mask(r)) = 0) then
                  bus_cacheable_i <= cp15_control(12) and cp15_pu_icache(r);
                  bus_cacheable_d <= cp15_control(2)  and cp15_pu_dcache(r);
               end if;
            end if;
         end loop;
      end if;
   end process;
   
   -- savestates
   -- ---------------------------------------------------------------------
   -- This core has no savestates - the bus exists only so nds_top can preset
   -- the boot PC and the r13 banks before it releases CPU reset, and nothing
   -- ever reads it back (ss_wired_out/ss_wired_done are `open` at all four
   -- instantiations; the debugger uses dbg_regsel/dbg_regval instead). Only
   -- addresses 0, 13, 14, 15, 24, 34 and 37 are ever written, so every other
   -- register here sits at its startVal forever - but Quartus cannot prove it
   -- because proc_bus.Adr is a runtime value, and builds all 47. That is a
   -- MEASURED 870 ALMs across cpu9/cpu7/itimer9/itimer7 that can never
   -- change, on a design fitting at 100%. Bit-exact to remove, and not a
   -- timing change - this is reset plumbing. Full rationale, including why
   -- CPUMIXED's startVal of 0xCC0 (supervisor, IRQ/FIQ disabled) must be
   -- preserved rather than zeroed, is in the matching block in gba_cpu.vhd.
   gss_full : if SS_PRESET_ONLY = '0' generate
   begin
   gSAVESTATE_REGS : for i in 0 to 15 generate
   begin
      iSAVESTATE_REGS : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, i) port map (clk, savestate_bus, save_wired_or(i), save_wired_done(i), std_logic_vector(regs(i)) , SAVESTATE_REGS(i));
   end generate;
   
   iSAVESTATE_REGS_16   : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, 16 ) port map (clk, savestate_bus, save_wired_or(16), save_wired_done(16), std_logic_vector(CPSR)      , open );
   iSAVESTATE_REGS_17   : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, 17 ) port map (clk, savestate_bus, save_wired_or(17), save_wired_done(17), std_logic_vector(SPSR)      , open );
   
   iSAVESTATE_PC        : entity work.eProcReg_gba generic map (REG_SAVESTATE_PC       ) port map (clk, savestate_bus, save_wired_or(18), save_wired_done(18), SAVESTATE_PC_out            , SAVESTATE_PC_in);
   
   iSAVESTATE_REGS_0_8  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_8 ) port map (clk, savestate_bus, save_wired_or(19), save_wired_done(19), std_logic_vector(regs_0_8 ) , SAVESTATE_REGS_0_8 );
   iSAVESTATE_REGS_0_9  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_9 ) port map (clk, savestate_bus, save_wired_or(20), save_wired_done(20), std_logic_vector(regs_0_9 ) , SAVESTATE_REGS_0_9 );
   iSAVESTATE_REGS_0_10 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_10) port map (clk, savestate_bus, save_wired_or(21), save_wired_done(21), std_logic_vector(regs_0_10) , SAVESTATE_REGS_0_10);
   iSAVESTATE_REGS_0_11 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_11) port map (clk, savestate_bus, save_wired_or(22), save_wired_done(22), std_logic_vector(regs_0_11) , SAVESTATE_REGS_0_11);
   iSAVESTATE_REGS_0_12 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_12) port map (clk, savestate_bus, save_wired_or(23), save_wired_done(23), std_logic_vector(regs_0_12) , SAVESTATE_REGS_0_12);
   iSAVESTATE_REGS_0_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_13) port map (clk, savestate_bus, save_wired_or(24), save_wired_done(24), std_logic_vector(regs_0_13) , SAVESTATE_REGS_0_13);
   iSAVESTATE_REGS_0_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_14) port map (clk, savestate_bus, save_wired_or(25), save_wired_done(25), std_logic_vector(regs_0_14) , SAVESTATE_REGS_0_14);
   iSAVESTATE_REGS_1_8  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_8 ) port map (clk, savestate_bus, save_wired_or(26), save_wired_done(26), std_logic_vector(regs_1_8 ) , SAVESTATE_REGS_1_8 );
   iSAVESTATE_REGS_1_9  : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_9 ) port map (clk, savestate_bus, save_wired_or(27), save_wired_done(27), std_logic_vector(regs_1_9 ) , SAVESTATE_REGS_1_9 );
   iSAVESTATE_REGS_1_10 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_10) port map (clk, savestate_bus, save_wired_or(28), save_wired_done(28), std_logic_vector(regs_1_10) , SAVESTATE_REGS_1_10);
   iSAVESTATE_REGS_1_11 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_11) port map (clk, savestate_bus, save_wired_or(29), save_wired_done(29), std_logic_vector(regs_1_11) , SAVESTATE_REGS_1_11);
   iSAVESTATE_REGS_1_12 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_12) port map (clk, savestate_bus, save_wired_or(30), save_wired_done(30), std_logic_vector(regs_1_12) , SAVESTATE_REGS_1_12);
   iSAVESTATE_REGS_1_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_13) port map (clk, savestate_bus, save_wired_or(31), save_wired_done(31), std_logic_vector(regs_1_13) , SAVESTATE_REGS_1_13);
   iSAVESTATE_REGS_1_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_14) port map (clk, savestate_bus, save_wired_or(32), save_wired_done(32), std_logic_vector(regs_1_14) , SAVESTATE_REGS_1_14);
   iSAVESTATE_REGS_1_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_1_17) port map (clk, savestate_bus, save_wired_or(33), save_wired_done(33), std_logic_vector(regs_1_17) , SAVESTATE_REGS_1_17);
   iSAVESTATE_REGS_2_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_13) port map (clk, savestate_bus, save_wired_or(34), save_wired_done(34), std_logic_vector(regs_2_13) , SAVESTATE_REGS_2_13);
   iSAVESTATE_REGS_2_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_14) port map (clk, savestate_bus, save_wired_or(35), save_wired_done(35), std_logic_vector(regs_2_14) , SAVESTATE_REGS_2_14);
   iSAVESTATE_REGS_2_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_17) port map (clk, savestate_bus, save_wired_or(36), save_wired_done(36), std_logic_vector(regs_2_17) , SAVESTATE_REGS_2_17);
   iSAVESTATE_REGS_3_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_13) port map (clk, savestate_bus, save_wired_or(37), save_wired_done(37), std_logic_vector(regs_3_13) , SAVESTATE_REGS_3_13);
   iSAVESTATE_REGS_3_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_14) port map (clk, savestate_bus, save_wired_or(38), save_wired_done(38), std_logic_vector(regs_3_14) , SAVESTATE_REGS_3_14);
   iSAVESTATE_REGS_3_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_17) port map (clk, savestate_bus, save_wired_or(39), save_wired_done(39), std_logic_vector(regs_3_17) , SAVESTATE_REGS_3_17);
   iSAVESTATE_REGS_4_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_13) port map (clk, savestate_bus, save_wired_or(40), save_wired_done(40), std_logic_vector(regs_4_13) , SAVESTATE_REGS_4_13);
   iSAVESTATE_REGS_4_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_14) port map (clk, savestate_bus, save_wired_or(41), save_wired_done(41), std_logic_vector(regs_4_14) , SAVESTATE_REGS_4_14);
   iSAVESTATE_REGS_4_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_4_17) port map (clk, savestate_bus, save_wired_or(42), save_wired_done(42), std_logic_vector(regs_4_17) , SAVESTATE_REGS_4_17);
   iSAVESTATE_REGS_5_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_13) port map (clk, savestate_bus, save_wired_or(43), save_wired_done(43), std_logic_vector(regs_5_13) , SAVESTATE_REGS_5_13);
   iSAVESTATE_REGS_5_14 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_14) port map (clk, savestate_bus, save_wired_or(44), save_wired_done(44), std_logic_vector(regs_5_14) , SAVESTATE_REGS_5_14);
   iSAVESTATE_REGS_5_17 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_5_17) port map (clk, savestate_bus, save_wired_or(45), save_wired_done(45), std_logic_vector(regs_5_17) , SAVESTATE_REGS_5_17);
   
   iSAVESTATE_CPUMIXED  : entity work.eProcReg_gba generic map (REG_SAVESTATE_CPUMIXED)  port map (clk, savestate_bus, save_wired_or(46), save_wired_done(46), SAVESTATE_mixed_out , SAVESTATE_mixed_in);
   
   process (save_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := save_wired_or(0);
      for i in 1 to (save_wired_or'length - 1) loop
         wired_or := wired_or or save_wired_or(i);
      end loop;
      ss_wired_out <= wired_or;
   end process;
   ss_wired_done <= '0' when (save_wired_done = 0) else '1';
   end generate;

   gss_preset : if SS_PRESET_ONLY = '1' generate
   begin
      -- The seven registers nds_top's preset_adr actually writes. wired_out is
      -- `open`, so each register's read mux and the 47-deep OR tree behind it
      -- go away too. REG_SAVESTATE_REGS is a size-18 block based at 1, so rN
      -- is at 1+N: addresses 13/14/15 are r12/r13/r14.
      gkeep_regs : for i in 12 to 14 generate
      begin
         iSAVESTATE_REGS : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, i) port map (clk, savestate_bus, open, open, std_logic_vector(regs(i)) , SAVESTATE_REGS(i));
      end generate;

      iSAVESTATE_PC        : entity work.eProcReg_gba generic map (REG_SAVESTATE_PC       ) port map (clk, savestate_bus, open, open, SAVESTATE_PC_out            , SAVESTATE_PC_in);

      -- r13 banks: 24 = user/system, 34 = IRQ, 37 = supervisor
      iSAVESTATE_REGS_0_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_0_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_0_13) , SAVESTATE_REGS_0_13);
      iSAVESTATE_REGS_2_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_2_13) , SAVESTATE_REGS_2_13);
      iSAVESTATE_REGS_3_13 : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_13) port map (clk, savestate_bus, open, open, std_logic_vector(regs_3_13) , SAVESTATE_REGS_3_13);

      -- Never written on this bus -> permanently startVal, which is 0 for all
      -- of these in reg_savestates.vhd.
      gzero_lo : for i in 0 to 11 generate
      begin
         SAVESTATE_REGS(i) <= (others => '0');
      end generate;
      SAVESTATE_REGS(15)  <= (others => '0');

      SAVESTATE_REGS_0_8  <= (others => '0');
      SAVESTATE_REGS_0_9  <= (others => '0');
      SAVESTATE_REGS_0_10 <= (others => '0');
      SAVESTATE_REGS_0_11 <= (others => '0');
      SAVESTATE_REGS_0_12 <= (others => '0');
      SAVESTATE_REGS_0_14 <= (others => '0');
      SAVESTATE_REGS_1_8  <= (others => '0');
      SAVESTATE_REGS_1_9  <= (others => '0');
      SAVESTATE_REGS_1_10 <= (others => '0');
      SAVESTATE_REGS_1_11 <= (others => '0');
      SAVESTATE_REGS_1_12 <= (others => '0');
      SAVESTATE_REGS_1_13 <= (others => '0');
      SAVESTATE_REGS_1_14 <= (others => '0');
      SAVESTATE_REGS_1_17 <= (others => '0');
      SAVESTATE_REGS_2_14 <= (others => '0');
      SAVESTATE_REGS_2_17 <= (others => '0');
      SAVESTATE_REGS_3_14 <= (others => '0');
      SAVESTATE_REGS_3_17 <= (others => '0');
      SAVESTATE_REGS_4_13 <= (others => '0');
      SAVESTATE_REGS_4_14 <= (others => '0');
      SAVESTATE_REGS_4_17 <= (others => '0');
      SAVESTATE_REGS_5_13 <= (others => '0');
      SAVESTATE_REGS_5_14 <= (others => '0');
      SAVESTATE_REGS_5_17 <= (others => '0');

      -- 0xCC0: cpu_mode = 3 (supervisor), IRQ and FIQ disabled. The one
      -- startVal on this bus that is not zero, and the boot flow needs it.
      SAVESTATE_mixed_in <= std_logic_vector(to_unsigned(16#CC0#, 12));

      ss_wired_out  <= (others => '0');
      ss_wired_done <= '0';
   end generate;

   SAVESTATE_mixed_out(0) <= decode_halt;           
   SAVESTATE_mixed_out(1) <= Flag_Zero;     
   SAVESTATE_mixed_out(2) <= Flag_Carry;     
   SAVESTATE_mixed_out(3) <= Flag_Negative;  
   SAVESTATE_mixed_out(4) <= Flag_V_Overflow;
   SAVESTATE_mixed_out(5) <= thumbmode;      
   SAVESTATE_mixed_out(9 downto 6) <= cpu_mode;       
   SAVESTATE_mixed_out(10) <= IRQ_disable;    
   SAVESTATE_mixed_out(11) <= FIQ_disable; 

   SAVESTATE_HALT            <= SAVESTATE_mixed_in(0);
   SAVESTATE_Flag_Zero       <= SAVESTATE_mixed_in(1);
   SAVESTATE_Flag_Carry      <= SAVESTATE_mixed_in(2);
   SAVESTATE_Flag_Negative   <= SAVESTATE_mixed_in(3);
   SAVESTATE_Flag_V_Overflow <= SAVESTATE_mixed_in(4);
   SAVESTATE_thumbmode       <= SAVESTATE_mixed_in(5);
   SAVESTATE_cpu_mode        <= SAVESTATE_mixed_in(9 downto 6);
   SAVESTATE_IRQ_disable     <= SAVESTATE_mixed_in(10);
   SAVESTATE_FIQ_disable     <= SAVESTATE_mixed_in(11);
   
   -- bus  
   process (all)
   begin

      gb_bus_ena  <= '0';
      gb_bus_save <= '0';

      if (reset = '0' and ce = '1') then

         if (bus_accessFetch = '1' and (busState <= BUSSTATE_IDLE or gb_bus_done = '1')) then
            gb_bus_ena  <= not dma_on;
            gb_bus_save <= dma_on;
         end if;
         
         if (execute_RW_ena = '1') then
            gb_bus_ena  <= not dma_on;
            gb_bus_save <= dma_on;
         end if;
         
         if (gb_bus_saved = '1' and dma_on = '0') then
            gb_bus_ena   <= '1';
         end if;

      end if;
         
   end process;
   
   
   process (clk)
   begin
      if (rising_edge(clk)) then
      
         dma_on_1 <= dma_on;
      
         if (reset = '1') then
         
            busState     <= BUSSTATE_IDLE;
            CPU_bus_idle <= '1';
            gb_bus_saved <= '0';
            
         elsif (ce = '1') then
         
            if (gb_bus_done = '1') then
               busState     <= BUSSTATE_IDLE;
               CPU_bus_idle <= '1';
               
               -- todo
               if (thumbmode = '1') then 
                  lastread     <= gb_bus_din(15 downto 0) & gb_bus_din(15 downto 0); 
               else
                  lastread     <= gb_bus_din; 
               end if;
            end if;
         
            if (bus_accessFetch = '1' and gb_bus_ena = '1') then
               busState     <= BUSSTATE_WAITFETCH;
               CPU_bus_idle <= '0';
            end if;
            
            if (execute_RW_ena = '1') then
               execute_RW_addr_last <= execute_RW_addr;
               if (gb_bus_ena = '1') then
                  busState             <= BUSSTATE_WAITDATA;
                  CPU_bus_idle         <= '0';
               end if;
            end if;
            
            if (gb_bus_saved = '1' and gb_bus_ena = '1') then
               CPU_bus_idle         <= '0';
               if (gb_bus_saved_st1 = '1') then
                  busState             <= BUSSTATE_WAITFETCH;
               else
                  busState             <= BUSSTATE_WAITDATA;
               end if;
            end if;
            
            if (gb_bus_save = '1') then
               gb_bus_saved      <= '1';
               gb_bus_saved_st1  <= bus_accessFetch;
               gb_bus_saved_Adr  <= gb_bus_Adr; 
               gb_bus_saved_rnw  <= gb_bus_rnw; 
               gb_bus_saved_seq  <= gb_bus_seq; 
               gb_bus_saved_acc  <= gb_bus_acc; 
               gb_bus_saved_dout <= gb_bus_dout;
            elsif (gb_bus_ena = '1') then
               gb_bus_saved <= '0';
            end if;

         end if;
         
      end if;
   end process;
   
   -- ===== PC-write fetch address: one mux level instead of two =====
   --
   -- When an instruction writes the PC, this cycle's ALU result becomes the next
   -- fetch address, and it used to get there through execute_writedata ->
   -- execute_branchPC -> (execute_branchPC_masked / bus_AddrFetch / gb_bus_Adr,
   -- which Quartus packs into one LUT). Measured on the worst path that tail is
   -- 3.55 ns for two levels, 2.94 ns of it interconnect - the muxes are cheap,
   -- the hops between them are not, and both levels select the same value.
   --
   -- So: strip the writedata term out of execute_branchPC entirely and give it a
   -- port on the LAST mux, past everything else. Every remaining input of
   -- adr_early is register-derived, so the late value crosses exactly one LUT.
   --
   -- The IRQ / software_interrupt exclusion is not a detail. execute_branch puts
   -- the PC-write case FIRST, but execute_branchPC puts the exception vectors
   -- first, so an exception that also writes the PC must still take the vector.
   -- Drop that condition and those branches go to the written value instead.
   pcwrite_fetch <= '1' when (execute_writeback = '1' and execute_writereg = x"F" and
                              decode_functions_detail /= IRQ and
                              decode_functions_detail /= software_interrupt_detail) else '0';

   -- what execute_branchPC_masked used to produce for that case: branchPC is
   -- writedata(31:1) & '0', then the mask clears bit 1 unless the target is
   -- thumb and always clears bit 0
   pcwrite_Addr <= execute_writedata(31 downto 2) &
                   (execute_writedata(1) and execute_nextIsthumb) & '0';

   -- the code-fetch address as actually presented on the bus. bus_AddrFetch no
   -- longer covers the PC-write case, so everything that consumed it as "the
   -- address we are fetching from" - fetch_PC's +2/+4 advance and the savestate
   -- PC - has to read this instead.
   bus_AddrFetch_eff <= pcwrite_Addr when (pcwrite_fetch = '1') else bus_AddrFetch;

   adr_early <= gb_bus_saved_Adr                when (gb_bus_saved = '1') else
                std_logic_vector(bus_AddrFetch) when (bus_accessFetch = '1') else
                std_logic_vector(execute_RW_addr);

   -- Tried spelling this out as the full five-term AND instead of reusing
   -- pcwrite_fetch, on the theory that it saves a LUT level and a 32-fanout
   -- broadcast in front of the final address mux (pcwrite_fetch is five levels
   -- downstream of the memory system's done). Measured the other way: build
   -- artifacts-t4 came out 0.12 ns worse than t2 with +335 ALMs, because
   -- duplicating the writereg compare is not free at 91% utilisation. Left
   -- sharing pcwrite_fetch.
   adr_is_pcw <= bus_accessFetch and pcwrite_fetch and not gb_bus_saved;

   gb_bus_Adr <= std_logic_vector(pcwrite_Addr) when (adr_is_pcw = '1') else adr_early;


   gb_bus_rnw  <= gb_bus_saved_rnw when (gb_bus_saved = '1') else 
                  '1'              when (bus_accessFetch = '1') else 
                  execute_RW_rnw;
   
   gb_bus_acc  <= gb_bus_saved_acc when (gb_bus_saved = '1') else 
                  "10"             when (bus_accessFetch = '1' and execute_nextIsthumb = '0') else 
                  "01"             when (bus_accessFetch = '1' and execute_nextIsthumb = '1') else 
                  execute_RW_acc;
   
   gb_bus_dout <= gb_bus_saved_dout when (gb_bus_saved = '1') else 
                  execute_RW_data;
   
   
   gb_bus_seq  <= gb_bus_saved_seq when (gb_bus_saved = '1') else
                  '1' when (bus_accessFetch = '1' and execute_branch = '0' and execute_stall = '0' and fetch_first = '0') else
                  '1' when (execute_RW_ena = '1' and (execute_RW_State = DATARW_BLOCKREAD or execute_RW_State = DATARW_BLOCKWRITE)) else
                  '0';
                  
   gb_bus_code <= gb_bus_saved_st1 when (gb_bus_saved = '1') else
                  '1'              when (bus_accessFetch = '1') else 
                  '0';
   
   -- fetch
   jump_out <= execute_branch and not execute_stall;
   
   bus_accessFetch <= '1' when (decode_unhalt = '1') else
                      '1' when (execute_done = '1' and decode_halt = '0') else 
                      '1' when (decode_ready = '0' and decode_halt = '0') else
                      '0';
                      
   bus_AddrFetch <= execute_branchPC_masked when (execute_branch = '1') else 
                    fetch_PC;
   
   fetch_done <= '1' when (busState = BUSSTATE_WAITFETCH and gb_bus_done = '1') else '0';
   
   process (clk)
   begin
      if (rising_edge(clk)) then
      
         if (reset = '1') then
         
            fetch_PC    <= unsigned(SAVESTATE_PC_in);
            fetch_ready <= '0';
            fetch_first <= '1';
         
         elsif (ce = '1') then
            
            fetch_first <= '0';
            
            --if (bus_accessFetch = '1' and gb_bus_ena = '1' and (busState = BUSSTATE_IDLE or gb_bus_done = '1')) then
            if (gb_bus_code = '1' and gb_bus_ena = '1') then
               if (execute_nextIsthumb = '1') then
                  fetch_PC <= bus_AddrFetch_eff + 2;
               else
                  fetch_PC <= bus_AddrFetch_eff + 4;
               end if;
            end if;
            
            if (fetch_done = '1') then
               fetch_data  <= gb_bus_din;
-- synthesis translate_off
               if (thumbmode = '1') then
                  fetch_data(31 downto 16) <= (others => '0');
               end if;
-- synthesis translate_on
               fetch_ready <= '1'; 
            end if;
            
            -- bus_AddrFetch_eff, not execute_branchPC_masked: pcwrite_fetch = '1'
            -- implies execute_branch = '1', so inside this branch the two are the
            -- same value - and only the former still carries the PC-write case.
            if (execute_branch = '1') then
               fetch_ready <= '0';
               if ((execute_stall = '1' and execute_done = '0') or dma_on = '1') then
                  fetch_PC <= bus_AddrFetch_eff;
               end if;
            end if;

            if (jump_out = '1') then
               SAVESTATE_PC_out <= std_logic_vector(bus_AddrFetch_eff);
            end if;

         end if;
         
      end if;
   end process;
   
   
   -- decode
   
   decode_data <= decode_data_1 when (execute_stall = '1') else fetch_data;
   
   process (clk) 
      variable opcode_high3      : std_logic_vector(2 downto 0);
      variable opcode_mid        : std_logic_vector(3 downto 0);
      variable opcode_low        : std_logic_vector(3 downto 0);
      variable bitcount8_low     : integer range 0 to 8;
      variable bitcount8_high    : integer range 0 to 8;
      
      variable decode_functions  : tFunctions;
      variable decode_datacomb   : std_logic_vector(27 downto 0) := (others => '0');
      variable decode_blockbits  : std_logic_vector(15 downto 0) := (others => '0');
      
      -- decoding details
      variable opcode       : std_logic_vector(3 downto 0);
      variable use_imm      : std_logic;
      variable updateflags  : std_logic;
      variable Rn_op1       : std_logic_vector(3 downto 0);
      variable Rdest        : std_logic_vector(3 downto 0);
      variable RM_op2       : std_logic_vector(3 downto 0);
      variable OP2          : std_logic_vector(11 downto 0);
      
      variable rotateamount  : unsigned(4 downto 0);
      variable immidiate    : unsigned(31 downto 0);
      variable shiftcarry   : std_logic;
      variable useoldcarry  : std_logic;

      variable v5_blximm    : std_logic; -- ARM BLX <label> (cond=1111)
      variable v5_blxreg    : std_logic; -- Thumb BLX Rm

   begin
   
      if (rising_edge(clk)) then
   
         if (reset = '1') then
         
            decode_ready   <= '0';
            decode_halt    <= SAVESTATE_HALT;
            decode_unhalt  <= '0';
         
         elsif (ce = '1') then
            
            decode_unhalt <= '0';
            
            if (execute_done = '1') then
               decode_ready <= '0';
            end if;
            
            if (new_halt = '1') then
               decode_halt <= '1';
            elsif (decode_halt = '1' and unhalt = '1') then
               decode_halt   <= '0';
               decode_unhalt <= '1';
            end if;
            
            if (execute_done = '0' and fetch_done = '1') then
               decode_data_1 <= fetch_data;
            end if;
            
            if (decode_functions_detail = block_read or decode_functions_detail = block_write) then
               if (execute_RW_ena = '1') then
                  decode_blockbits := decode_block_reglist;
                  decode_blockbits(to_integer(unsigned(decode_RM_op2))) := '0';
                  decode_block_reglist <= decode_blockbits;
                  for i in 15 downto 0 loop
                     if (decode_blockbits(i) = '1') then 
                        decode_RM_op2 <= std_logic_vector(to_unsigned(i,4));
                     end if;
                  end loop;
               end if;
            end if;
            
            if (execute_now = '1' and decode_shift_regbased = '1') then
               decode_Rn_op1 <= decode_Rn_op1_save;
               -- only Rs[7:0] participates; ROR by a nonzero multiple of 32
               -- must behave as ROR #32 (result unchanged, C := Rm[31]), not
               -- as ROR #0 (everything unchanged)
               if (decode_shift_mode = "11" and unsigned(execute_op1(7 downto 0)) > 32) then
                  if (unsigned(execute_op1(4 downto 0)) = 0) then
                     decode_shift_amount <= 32;
                  else
                     decode_shift_amount <= to_integer(unsigned(execute_op1(4 downto 0)));
                  end if;
               else
                  decode_shift_amount <= to_integer(unsigned(execute_op1(7 downto 0)));
               end if;
            end if;
            
            if (execute_now = '1' and decode_functions_detail = mulboth) then
               decode_Rn_op1 <= decode_Rn_op1_save;
               decode_RM_op2 <= decode_rdest_save;
            end if;

            -- v5TE DSP multiply operand swaps: after the multiply beat op1
            -- becomes the accumulate register (Rn or RdLo), and for the long
            -- form the following beat swaps it again to RdHi
            if (execute_now = '1' and decode_functions_detail = mul_dsp) then
               decode_Rn_op1 <= decode_Rn_op1_save;
            end if;
            if (execute_stall = '1' and decode_functions_detail = mul_dsp and execute_MUL_State = MUL_DSP_ACC) then
               decode_Rn_op1 <= decode_dsp_acchi;
            end if;

            -- CP15 wait-for-interrupt (MCR c7,c0,4) halts like HALTCNT does
            if (execute_wfi = '1') then
               decode_halt <= '1';
            end if;
            
            if (decode_halt = '0' and fetch_ready = '1' and (((fetch_done = '1' and decode_ready = '0') or execute_done = '1'))) then
               decode_ready <= '1';
               decode_PC    <= fetch_PC;
            
               -- synthesis translate_off
               decode_opcode_export <= decode_data;
               -- synthesis translate_on  
               
               decode_datacomb  := decode_data(27 downto 0);

               decode_clearbit1 <= '0';
               v5_blximm        := '0';
               v5_blxreg        := '0';
               
               bitcount8_low  := 0;
               bitcount8_high := 0;
               for i in 0 to 7 loop
                  if (decode_data(i) = '1')     then bitcount8_low  := bitcount8_low + 1;  end if;
                  if (decode_data(8 + i) = '1') then bitcount8_high := bitcount8_high + 1; end if;
               end loop;
         
               if (thumbmode = '0') then
               
                  decode_condition <= decode_data(31 downto 28);
      
                  opcode_high3  := decode_data(27 downto 25);
                  opcode_mid    := decode_data(24 downto 21);
                  opcode_low    := decode_data(7 downto 4);
         
                  case (to_integer(unsigned(opcode_high3))) is
                  
                     when 0 => -- (27..25) = 000 => alu commands?
                        case (opcode_low) is

                           when x"1" =>
                              if (decode_data(24 downto 8) = '1' & x"2FFF") then
                                 decode_functions := branch_and_exchange;
                                 --branch_and_exchange(RM_op2);
                              elsif (opcode_mid = x"B" and decode_data(20) = '0') then
                                 decode_functions := v5_misc; -- CLZ
                              else
                                 decode_functions := data_processing;
                                 --data_processing(use_imm, opcode_mid, updateflags, Rn_op1, Rdest, OP2, asmcmd);
                              end if;

                           when x"3" =>
                              if (opcode_mid = x"9" and decode_data(20) = '0') then
                                 decode_functions := branch_and_exchange; -- BLX reg (link from bit 5)
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"5" =>
                              if (decode_data(24 downto 23) = "10" and decode_data(20) = '0') then
                                 decode_functions := v5_misc; -- QADD/QSUB/QDADD/QDSUB
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"8" | x"A" | x"C" | x"E" =>
                              if (decode_data(24 downto 23) = "10" and decode_data(20) = '0') then
                                 decode_functions := v5_misc; -- SMULxy/SMLAxy/SMULWy/SMLAWy/SMLALxy
                              else
                                 decode_functions := data_processing;
                              end if;

                           when x"9" =>
                              if (unsigned(opcode_mid) >= 8) then
                                 decode_functions := single_data_swap;
                                 --single_data_swap((opcode_mid & 2) == 2, Rn_op1, Rdest, OP2);
                              elsif (unsigned(opcode_mid) >= 4) then
                                 decode_functions := multiply_long;
                                 --multiply_long(opcode_mid, updateflags, Rn_op1, Rdest, OP2);
                              else
                                 decode_functions := multiply;
                                 --multiply(opcode_mid, updateflags, Rdest, Rn_op1, (byte)((OP2 >> 8) & 0xF), (byte)(OP2 & 0xF));
                              end if;

                           when x"B" | x"D" | x"F" =>  -- halfword data transfer (v5TE: incl. LDRD/STRD, see details)
                              if (decode_data(22) = '1') then --  immidiate offset
                                 decode_functions := halfword_data_transfer_immoffset;
                                 --halfword_data_transfer(opcode_mid, opcode_low, updateflags, Rn_op1, Rdest, (UInt32)(((OP2 >> 4) & 0xF0) | RM_op2));
                              else -- register offset
                                 decode_functions := halfword_data_transfer_regoffset;
                                 --halfword_data_transfer(opcode_mid, opcode_low, updateflags, Rn_op1, Rdest, regs[RM_op2]);
                              end if;

                           when others =>
                              decode_functions := data_processing;
                              --data_processing(use_imm, opcode_mid, updateflags, Rn_op1, Rdest, OP2, asmcmd);

                        end case;
         
                     when 1 =>
                        decode_functions := data_processing;
                        --data_processing(use_imm, opcode_mid, updateflags, Rn_op1, Rdest, OP2, asmcmd);
         
                     when 2 | 3 =>
                        decode_functions := single_data_transfer;
                        --single_data_transfer(use_imm, opcode_mid, opcode_low, updateflags, Rn_op1, Rdest, OP2);
         
                     when 4 => 
                        decode_functions := block_data_transfer;
                        --block_data_transfer(opcode_mid, updateflags, Rn_op1, (UInt16)asmcmd);
         
                     when 5 =>
                        decode_functions := branch;
                        --branch((opcode_mid & 8) == 8, asmcmd & 0xFFFFFF);

                     when 6 =>
                        decode_functions := v5_nop; -- LDC/STC: no such coprocessor on the NDS ARM9

                     when 7 =>
                        if (decode_data(24) = '1') then
                           decode_functions := software_interrupt;
                           --software_interrupt();
                        elsif (decode_data(4) = '1') then
                           decode_functions := coprocessor_op; -- MCR/MRC
                        else
                           decode_functions := v5_nop;         -- CDP
                        end if;

                     when others => null;
                        --report "should never happen" severity failure;

                  end case;

                  -- cond = 1111: the v5 unconditional space. BLX imm switches to
                  -- Thumb and always links; everything else here is treated as a
                  -- nop (PLD is architecturally a hint).
                  if (decode_data(31 downto 28) = x"F") then
                     decode_condition <= x"E";
                     if (opcode_high3 = "101") then
                        decode_functions := branch;
                        v5_blximm        := '1';
                     else
                        decode_functions := v5_nop;
                     end if;
                  end if;

               else  -- thumb
               
                  decode_condition <= x"E";
               
                  case (to_integer(unsigned(decode_data(15 downto 13)))) is
               
                     when 0 => 
                        if (decode_data(12 downto 11) = "11") then
                           decode_datacomb(27 downto 26)  := "00"; -- fixed
                           decode_datacomb(25)            := decode_data(10);  -- Immidiate
                           if (decode_data(9) = '1') then
                              decode_datacomb(24 downto 21)  := x"2"; -- Opcode -> sub
                           else
                              decode_datacomb(24 downto 21)  := x"4"; -- Opcode -> add
                           end if;
                           decode_datacomb(20)            := '1'; -- set condition codes
                           decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- RN -> 1st op
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                           if (decode_data(10) = '1') then
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(8 downto 6); -- 3 bit immidiate, no rotate
                           else
                              decode_datacomb(11 downto  4)  := x"00"; -- don't shift
                              decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6); -- Rm -> 2nd OP
                           end if;
                           decode_functions := data_processing;
                           --add_subtract(((asmcmd >> 10) & 1) == 1, ((asmcmd >> 9) & 1) == 1, (byte)((asmcmd >> 6) & 0x7), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                        else
                           decode_datacomb(27 downto 26)  := "00"; -- fixed
                           decode_datacomb(25)            := '0';  -- Immidiate
                           decode_datacomb(24 downto 21)  := x"D"; -- Opcode -> mov
                           decode_datacomb(20)            := '1'; -- set condition codes
                           decode_datacomb(19 downto 16)  := x"0"; -- RN -> 1st op
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                           decode_datacomb(11 downto  7)  := decode_data(10 downto 6);  -- shift amount
                           decode_datacomb( 6 downto  5)  := decode_data(12 downto 11); -- shift type
                           decode_datacomb( 4)            := '0';  -- shift with immidiate
                           decode_datacomb( 3 downto  0)  := '0' & decode_data(5 downto 3); -- Rm -> 2nd OP
                           decode_functions := data_processing;
                           --move_shifted_register((byte)((asmcmd >> 11) & 3), (byte)((asmcmd >> 6) & 0x1F), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                        end if;
                     
                     when 1 =>
                        decode_datacomb(27 downto 26)  := "00"; -- fixed
                        decode_datacomb(25)            := '1';  -- Immidiate
                        case (decode_data(12 downto 11)) is
                           when "00" => decode_datacomb(24 downto 21)  := x"D"; -- Opcode -> mov
                           when "01" => decode_datacomb(24 downto 21)  := x"A"; -- Opcode -> cmp
                           when "10" => decode_datacomb(24 downto 21)  := x"4"; -- Opcode -> add
                           when "11" => decode_datacomb(24 downto 21)  := x"2"; -- Opcode -> sub
                           when others => report "should never happen" severity failure;
                        end case;
                        decode_datacomb(20)            := '1'; -- set condition codes
                        decode_datacomb(19 downto 16)  := '0' & decode_data(10 downto 8); -- RN -> 1st op
                        decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8); -- Rdest
                        decode_datacomb(11 downto  0)  := x"0" & decode_data(7 downto 0); -- 8 bit immidiate, no rotate
                        decode_functions := data_processing;
                        --move_compare_add_subtract_immediate((byte)((asmcmd >> 11) & 3), (byte)((asmcmd >> 8) & 7), (byte)(asmcmd & 0xFF));
               
                     when 2 =>
                        case (to_integer(unsigned(decode_data(12 downto 10)))) is
                           
                           when 0 =>
                              decode_datacomb(27 downto 26)  := "00"; -- fixed
                              decode_datacomb(25)            := '0';  -- Immidiate
                              decode_datacomb(20)            := '1'; -- set condition codes
                              decode_datacomb(19 downto 16)  := '0' & decode_data(2 downto 0); -- RN -> 1st op
                              decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(5 downto 3); -- RS -> 2nd OP -> no shift using op2 is default
                              decode_functions := data_processing;
                              case (decode_data(9 downto 6)) is
                                 when x"0" => decode_datacomb(24 downto 21)  := x"0"; -- 0000 AND Rd, Rs ANDS Rd, Rd, Rs Rd:= Rd AND Rs
                                 when x"1" => decode_datacomb(24 downto 21)  := x"1"; -- 0001 EOR Rd, Rs EORS Rd, Rd, Rs Rd:= Rd EOR Rs
                                 
                                 when x"2" =>                                         -- 0010 LSL Rd, Rs MOVS Rd, Rd, LSL Rs Rd := Rd << Rs
                                    decode_datacomb(24 downto 21)  := x"D"; 
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0001" & '0' & decode_data(2 downto 0);
                                 
                                 when x"3" =>                                         -- 0011 LSR Rd, Rs MOVS Rd, Rd, LSR Rs Rd := Rd >> Rs
                                    decode_datacomb(24 downto 21)  := x"D"; 
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0011" & '0' & decode_data(2 downto 0);
                                    
                                 when x"4" =>                                         -- 0100 ASR Rd, Rs MOVS Rd, Rd, ASR Rs Rd := Rd ASR Rs
                                    decode_datacomb(24 downto 21)  := x"D"; 
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0101" & '0' & decode_data(2 downto 0);
                                    
                                 when x"5" => decode_datacomb(24 downto 21)  := x"5"; -- 0101 ADC Rd, Rs ADCS Rd, Rd, Rs Rd:= Rd + Rs + C - bit
                                 when x"6" => decode_datacomb(24 downto 21)  := x"6"; -- 0110 SBC Rd, Rs SBCS Rd, Rd, Rs Rd:= Rd - Rs - NOT C - bit
                                 
                                 when x"7" =>                                         -- 0111 ROR Rd, Rs MOVS Rd, Rd, ROR Rs Rd := Rd ROR Rs
                                    decode_datacomb(24 downto 21)  := x"D"; 
                                    decode_datacomb(11 downto  0)  := '0' & decode_data(5 downto 3) & "0111" & '0' & decode_data(2 downto 0);                              
                  
                                 when x"8" => decode_datacomb(24 downto 21)  := x"8"; -- 1000 TST Rd, Rs TST Rd, Rs Set condition codes on Rd AND Rs
                                 
                                 when x"9" =>                                         -- 1001 NEG Rd, Rs RSBS Rd, Rs, #0 Rd = -Rs
                                    decode_datacomb(24 downto 21)  := x"3"; 
                                    decode_datacomb(25)            := '1';  -- Immidiate
                                    decode_datacomb(11 downto  0)  := x"000";
                                    decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- RS as 1st op
                                    
                                 when x"A" => decode_datacomb(24 downto 21)  := x"A"; -- 1010 CMP Rd, Rs CMP Rd, Rs Set condition codes on Rd - Rs
                                 when x"B" => decode_datacomb(24 downto 21)  := x"B"; -- 1011 CMN Rd, Rs CMN Rd, Rs Set condition codes on Rd + Rs
                                 when x"C" => decode_datacomb(24 downto 21)  := x"C"; -- 1100 ORR Rd, Rs ORRS Rd, Rd, Rs Rd:= Rd OR Rs
                                 
                                 when x"D" =>                                      -- 1101 MUL Rd, Rs MULS Rd, Rs, Rd Rd:= Rs * Rd
                                    decode_datacomb(27 downto 20)  := x"01"; -- fixed 
                                    decode_datacomb( 7 downto  4)  := x"9";  -- fixed 
                                    decode_datacomb(11 downto  8)  := '0' & decode_data(2 downto 0); -- multiplier
                                    decode_functions := multiply;
                                    
                                 when x"E" => decode_datacomb(24 downto 21)  := x"E"; -- 1110 BIC Rd, Rs BICS Rd, Rd, Rs Rd:= Rd AND NOT Rs
                                 when x"F" => decode_datacomb(24 downto 21)  := x"F"; -- 1111 MVN Rd, Rs MVNS Rd, Rs Rd:= NOT Rs
                                 when others => report "should never happen" severity failure;
                              end case;
                              
                              --alu_operations((byte)((asmcmd >> 6) & 0xF), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                           
                           when 1 =>
                              decode_datacomb(27 downto 26)  := "00"; -- fixed
                              decode_datacomb(25)            := '0';  -- Immidiate
                              decode_datacomb(20)            := '0'; -- set condition codes
                              decode_datacomb(19 downto 16)  := '0' & decode_data(2 downto 0); -- RN -> 1st op
                              decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                              decode_datacomb(11 downto  0)  := x"00" & '0' & decode_data(5 downto 3); -- RS -> 2nd OP -> no shift using op2 is default
                              decode_functions               := data_processing;
                              case (decode_data(9 downto 6)) is
                                 when x"1" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb( 3) := '1';                                                         -- 0001 ADD Rd, Hs ADD Rd, Rd, Hs Add a register in the range 8 - 15 to a register in the range 0 - 7.
                                 when x"2" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';                             -- 0010 ADD Hd, Rs ADD Hd, Hd, Rs Add a register in the range 0 - 7 to a register in the range 8 - 15.
                                 when x"3" => decode_datacomb(24 downto 21) := x"4"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1'; -- 0011 ADD Hd, Hs ADD Hd, Hd, Hs Add two registers in the range 8 - 15
                                                                                    
                                 when x"5" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb( 3) := '1';                                                         decode_datacomb(20) := '1'; -- 0101 CMP Rd, Hs CMP Rd, Hs Compare a register in the range 0 - 7 with a register in the range 8 - 15.Set the condition code flags on the result.
                                 when x"6" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';                             decode_datacomb(20) := '1'; -- 0110 CMP Hd, Rs CMP Hd, Rs Compare a register in the range 8 - 15 with a register in the range 0 - 7.Set the condition code flags on the result.
                                 when x"7" => decode_datacomb(24 downto 21) := x"A"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1'; decode_datacomb(20) := '1'; -- 0111 CMP Hd, Hs CMP Hd, Hs Compare two registers in the range 8 - 15.Set the condition code flags on the result.
                                                                                                                                                                        
                                 when x"8" => decode_datacomb(24 downto 21) := x"D";                                                                                     -- 1000 -> undefined but probably just using low for both  
                                 when x"9" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb( 3) := '1';                                                         -- 1001 MOV Rd, Hs MOV Rd, Hs Move a value from a register in the range 8 - 15 to a register in the range 0 - 7.  
                                 when x"A" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb(19) := '1'; decode_datacomb(15) := '1';                             -- 1010 MOV Hd, Rs MOV Hd, Rs Move a value from a register in the range 0 - 7 to a register in the range 8 - 15.
                                 when x"B" => decode_datacomb(24 downto 21) := x"D"; decode_datacomb( 3) := '1'; decode_datacomb(19) := '1'; decode_datacomb(15) := '1'; -- 1011 MOV Hd, Hs MOV Hd, Hs Move a value between two registers in the range 8 - 15.
                                                                                    
                                 when x"C" => decode_functions := branch_and_exchange;                             -- 1100 BX Rs Perform branch(plus optional state change) to address in a register in the range 0 - 7.
                                 when x"D" => decode_functions := branch_and_exchange; decode_datacomb(3) := '1';  -- 1101 BX Hs Perform branch(plus optional state change) to address in a register in the range 8 - 15.
                                 when x"E" => decode_functions := branch_and_exchange; v5_blxreg := '1';           -- 1110 BLX Rs (v5T)
                                 when x"F" => decode_functions := branch_and_exchange; v5_blxreg := '1'; decode_datacomb(3) := '1'; -- 1111 BLX Hs (v5T)
      
                                 -- can't do this check, as prefetch may fetch data that could contain this
                                 --when others => report "decode_data(12 downto 10) = 1 => case should never happen" severity failure;
                                 when others => null;
                              end case;
                              
                              --hi_register_operations_branch_exchange((byte)((asmcmd >> 6) & 0xF), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));   
                     
                           when 2 | 3 =>
                              decode_datacomb(27 downto 26)  := "01"; -- fixed
                              decode_datacomb(25)            := '0';  -- offset is immidiate
                              decode_datacomb(24)            := '1';  -- pre add offset
                              decode_datacomb(23)            := '1';  -- add offset
                              decode_datacomb(22)            := '0';  -- word
                              decode_datacomb(21)            := '0';  -- writeback
                              decode_datacomb(20)            := decode_data(11); -- read/write
                              decode_datacomb(19 downto 16)  := x"F"; -- base register
                              decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8); -- Rdest
                              decode_datacomb(11 downto  0)  := "00" & decode_data(7 downto 0) & "00"; -- offset immidiate
                              decode_functions := single_data_transfer;
                              --pc_relative_load((byte)((asmcmd >> 8) & 0x7), (byte)(asmcmd & 0xFF));
                              
                           when 4 | 5 | 6 | 7 =>
                              if (decode_data(9) = '0') then
                                 decode_datacomb(27 downto 26)  := "01"; -- fixed
                                 decode_datacomb(25)            := '1';  -- offset is reg
                                 decode_datacomb(24)            := '1';  -- pre add offset
                                 decode_datacomb(23)            := '1';  -- add offset
                                 decode_datacomb(22)            := decode_data(10);  -- byte/word
                                 decode_datacomb(21)            := '0';  -- writeback
                                 decode_datacomb(20)            := decode_data(11); -- read/write
                                 decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- base register
                                 decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                                 decode_datacomb(11 downto  4)  := x"00"; -- don't shift
                                 decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6); -- offset register
                                 decode_functions := single_data_transfer;
                                 --load_store_with_register_offset(((asmcmd >> 11) & 1) == 1, ((asmcmd >> 10) & 1) == 1, (byte)((asmcmd >> 6) & 0x7), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                              else
                                 decode_datacomb(27 downto 25)  := "000"; -- fixed
                                 decode_datacomb(24)            := '1';  -- pre add offset
                                 decode_datacomb(23)            := '1';  -- add offset
                                 decode_datacomb(22)            := '1';  -- fixed
                                 decode_datacomb(21)            := '0';  -- writeback
                                 decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- base register
                                 decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                                 decode_datacomb(11 downto  8)  := "0000"; -- fixed
                                 decode_datacomb( 7)            := '1'; -- fixed
                                 decode_datacomb( 4)            := '1'; -- fixed
                                 decode_datacomb( 3 downto  0)  := '0' & decode_data(8 downto 6); -- offset register
                                 case (decode_data(11 downto 10)) is -- read     S                             H
                                    when "00" => decode_datacomb(20) := '0'; decode_datacomb(6) := '0'; decode_datacomb(5) := '1'; -- Store halfword
                                    when "01" => decode_datacomb(20) := '1'; decode_datacomb(6) := '1'; decode_datacomb(5) := '0'; -- Load sign-extended byte
                                    when "10" => decode_datacomb(20) := '1'; decode_datacomb(6) := '0'; decode_datacomb(5) := '1'; -- Load halfword
                                    when "11" => decode_datacomb(20) := '1'; decode_datacomb(6) := '1'; decode_datacomb(5) := '1'; -- Load sign-extended halfword
                                    when others => null;  
                                 end case;
                                 decode_functions := halfword_data_transfer_regoffset;
                                 --load_store_sign_extended_byte_halfword((byte)((asmcmd >> 10) & 0x3), (byte)((asmcmd >> 6) & 0x7), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                              end if;
                              
                           when others => report "should never happen" severity failure;
                     
                        end case;
                     
                     when 3 =>
                        decode_datacomb(27 downto 26)  := "01"; -- fixed
                        decode_datacomb(25)            := '0';  -- offset is reg
                        decode_datacomb(24)            := '1';  -- pre add offset
                        decode_datacomb(23)            := '1';  -- add offset
                        decode_datacomb(22)            := decode_data(12);  -- dword
                        decode_datacomb(21)            := '0';  -- writeback
                        decode_datacomb(20)            := decode_data(11); -- read/write
                        decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- base register
                        decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                        if (decode_data(12) = '1') then -- byte -> 5 bit address
                           decode_datacomb(11 downto  0)  := "0000000" & decode_data(10 downto 6); -- offset immidiate
                        else
                           decode_datacomb(11 downto  0)  := "00000" & decode_data(10 downto 6) & "00"; -- offset immidiate
                        end if;
                        decode_functions := single_data_transfer;
                        --load_store_with_immidiate_offset(((asmcmd >> 11) & 1) == 1, ((asmcmd >> 12) & 1) == 1, (byte)((asmcmd >> 6) & 0x1F), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                     
                     when 4 =>
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 25)  := "000"; -- fixed
                           decode_datacomb(24)            := '1';  -- pre add offset
                           decode_datacomb(23)            := '1';  -- add offset
                           decode_datacomb(22)            := '1';  -- fixed
                           decode_datacomb(21)            := '0';  -- writeback
                           decode_datacomb(20)            := decode_data(11); -- read/write
                           decode_datacomb(19 downto 16)  := '0' & decode_data(5 downto 3); -- base register
                           decode_datacomb(15 downto 12)  := '0' & decode_data(2 downto 0); -- Rdest
                           decode_datacomb(11 downto  8)  := "00" & decode_data(10 downto 9); -- offset immidiate
                           decode_datacomb( 7)            := '1'; -- fixed
                           decode_datacomb( 6)            := '0'; -- S
                           decode_datacomb( 5)            := '1'; -- H
                           decode_datacomb( 4)            := '1'; -- fixed
                           decode_datacomb( 3 downto  0)  := decode_data(8 downto 6) & '0'; -- offset immidiate
                           decode_functions := halfword_data_transfer_immoffset;
                           --load_store_halfword(((asmcmd >> 11) & 1) == 1, (byte)((asmcmd >> 6) & 0x1F), (byte)((asmcmd >> 3) & 0x7), (byte)(asmcmd & 0x7));
                        else
                           decode_datacomb(27 downto 26)  := "01"; -- fixed
                           decode_datacomb(25)            := '0';  -- offset is reg
                           decode_datacomb(24)            := '1';  -- pre add offset
                           decode_datacomb(23)            := '1';  -- add offset
                           decode_datacomb(22)            := '0';  -- dword
                           decode_datacomb(21)            := '0';  -- writeback
                           decode_datacomb(20)            := decode_data(11); -- read/write
                           decode_datacomb(19 downto 16)  := x"D"; -- base register
                           decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8); -- Rdest
                           decode_datacomb(11 downto  0)  := "00" & decode_data(7 downto 0) & "00"; -- offset immidiate
                           decode_functions := single_data_transfer;
                           --sp_relative_load_store(((asmcmd >> 11) & 1) == 1, (byte)((asmcmd >> 8) & 0x7), (byte)(asmcmd & 0xFF));
                        end if;
                        
                     when 5 =>
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 26)  := "00"; -- fixed
                           decode_datacomb(25)            := '1';  -- Immidiate
                           decode_datacomb(24 downto 21)  := x"4"; -- Opcode -> add
                           decode_datacomb(20)            := '0';  -- set condition codes
                           if (decode_data(11) = '1') then -- stack pointer 13(1) or PC(15)
                              decode_datacomb(19 downto 16)  := x"D"; -- RN -> 1st op
                           else 
                              decode_datacomb(19 downto 16)  := x"F"; -- RN -> 1st op
                              decode_clearbit1               <= '1';
                           end if;
                           decode_datacomb(15 downto 12)  := '0' & decode_data(10 downto 8); -- Rdest
                           decode_datacomb(11 downto  0)  := x"F" & decode_data(7 downto 0); -- 8 bit immidiate, shift left by 2
                           decode_functions := data_processing;
                           --load_address(((asmcmd >> 11) & 1) == 1, (byte)((asmcmd >> 8) & 0x7), (byte)(asmcmd & 0xFF));
                        else
                           if (decode_data(10) = '0') then
                              decode_datacomb(27 downto 26)  := "00"; -- fixed
                              decode_datacomb(25)            := '1';  -- Immidiate
                              if (decode_data(7) = '1') then -- sign bit
                                 decode_datacomb(24 downto 21)  := x"2"; -- Opcode -> sub
                              else 
                                 decode_datacomb(24 downto 21)  := x"4"; -- Opcode -> add
                              end if;
                              decode_datacomb(20)            := '0'; -- set condition codes
                              decode_datacomb(19 downto 16)  := x"D"; -- RN -> 1st op
                              decode_datacomb(15 downto 12)  := x"D"; -- Rdest
                              decode_datacomb(11 downto  0)  := x"F" & '0' & decode_data(6 downto 0); -- 8 bit immidiate, shift left by 2
                              decode_functions := data_processing;
                              --add_offset_to_stack_pointer(((asmcmd >> 7) & 1) == 1, (byte)(asmcmd & 0x7F));
                           else
                              decode_datacomb(27 downto 25)  := "100"; -- fixed
                              decode_datacomb(22)            := '0'; -- PSR
                              decode_datacomb(21)            := '1'; -- Writeback
                              decode_datacomb(20)            := decode_data(11); -- Load
                              decode_datacomb(15 downto 0)   := x"00" & decode_data(7 downto 0); -- reglist
                              decode_datacomb(19 downto 16)  := x"D"; -- base register -> 13
                              bitcount8_high := 0;
                              if (decode_data(8) = '1') then -- link
                                 bitcount8_high := 1;
                                 if (decode_data(11) = '1') then -- load
                                    decode_datacomb(15) := '1';
                                 else
                                    decode_datacomb(14) := '1';
                                 end if;
                              end if;
                              -- LDMIA!  opcode = !pre up !csr store  <-> // STMDB !  opcode = pre !up !csr store
                              decode_datacomb(24) := not decode_data(11); -- Pre
                              decode_datacomb(23) := decode_data(11);     -- up
                              decode_functions := block_data_transfer;
                              --push_pop_register(((asmcmd >> 11) & 1) == 1, ((asmcmd >> 8) & 1) == 1, (byte)(asmcmd & 0xFF));
                           end if;
                        end if;
                        
                     when 6 => 
                        if (decode_data(12) = '0') then
                           decode_datacomb(27 downto 25)  := "100"; -- fixed
                           decode_datacomb(24)            := '0'; -- Pre
                           decode_datacomb(23)            := '1'; -- up
                           decode_datacomb(22)            := '0'; -- PSR
                           decode_datacomb(21)            := '1'; -- Writeback
                           decode_datacomb(20)            := decode_data(11); -- Load
                           decode_datacomb(19 downto 16)  := '0' & decode_data(10 downto 8); -- base register
                           decode_datacomb(15 downto 0)   := x"00" & decode_data(7 downto 0); -- reglist
                           bitcount8_high                 := 0;
                           decode_functions               := block_data_transfer;
                           --multiple_load_store(((asmcmd >> 11) & 1) == 1, (byte)((asmcmd >> 8) & 0x7), (byte)(asmcmd & 0xFF));
                        else
                           if (decode_data(11 downto 8) = x"F") then
                              decode_functions := software_interrupt;
                              --software_interrupt();
                           else
                              decode_datacomb(27 downto 25) := "101"; -- fixed
                              decode_datacomb(24)           := '0';   -- without link
                              decode_datacomb(23 downto 0)  := std_logic_vector(resize(signed(decode_data(7 downto 0)), 24));
                              decode_condition              <= decode_data(11 downto 8);
                              decode_functions := branch;
                              --conditional_branch((byte)((asmcmd >> 8) & 0xF), (byte)(asmcmd & 0xFF));
                           end if;
                        end if;
                           
                     when 7 =>
                        if (decode_data(12) = '0') then
                           if (decode_data(11) = '1') then
                              -- BLX suffix (v5T): like the BL suffix, but the
                              -- target is ARM state and word-aligned
                              decode_datacomb(11) := '1';
                              decode_functions    := long_branch_with_link;
                              v5_blxreg           := '1'; -- reused: force-ARM marker
                           else
                              decode_datacomb(27 downto 25) := "101"; -- fixed
                              decode_datacomb(24)           := '0';   -- without link
                              decode_datacomb(23 downto 0)  := std_logic_vector(resize(signed(decode_data(10 downto 0)), 24));
                              decode_functions := branch;
                              --unconditional_branch((UInt16)(asmcmd & 0x7FF));
                           end if;
                        else
                           decode_functions := long_branch_with_link;
                           --long_branch_with_link(((asmcmd >> 11) & 1) == 1, (UInt16)(asmcmd & 0x7FF));
                        end if;
                     
                     when others => report "should never happen" severity failure; 
               
                  end case;
               
               end if;
      
               -- decoding details
         
               use_imm       := decode_datacomb(25);
               updateflags   := decode_datacomb(20);
               Rn_op1        := decode_datacomb(19 downto 16);
               Rdest         := decode_datacomb(15 downto 12);
               RM_op2        := decode_datacomb(3 downto 0);
               OP2           := decode_datacomb(11 downto 0);
               opcode        := decode_datacomb(24 downto 21);
            
               decode_updateflags            <= '1';
               decode_alu_use_immi           <= '0';
               decode_alu_use_shift          <= '0';
               decode_switch_op              <= '0';
               decode_datatransfer_shiftval  <= '0';
               decode_datatransfer_regoffset <= '0';
               decode_datatransfer_swap      <= '0';
               decode_datatransfer_writeback <= '0';
               decode_leaveirp               <= '0';
               decode_branch_long            <= '0';
               decode_set_thumbmode          <= '0';
               decode_writeback              <= '0';
               decode_datatransfer_double    <= '0';
               decode_branch_forcethumb      <= '0';
               decode_branch_forcearm        <= '0';
               
               decode_shift_regbased   <= '0';
               decode_shift_mode       <= decode_datacomb(6 downto 5);
               decode_shift_amount     <= to_integer(unsigned(decode_datacomb(11 downto 7)));
               decode_shift_RRX        <= '0';
               
               if (decode_datacomb(4) = '0') then --shift by immidiate 
                  if ((decode_datacomb(6 downto 5) = "01" or decode_datacomb(6 downto 5) = "10") and decode_datacomb(11 downto 7) = "00000") then
                     decode_shift_amount <= 32;
                  end if;
                  
                  if (decode_datacomb(6 downto 5) = "11" and decode_datacomb(11 downto 7) = "00000") then
                     decode_shift_RRX <= '1';
                  end if;
               end if;
         
               case (decode_functions) is 
                  when data_processing =>
               
                     -- imidiate calculation
                     rotateamount := unsigned(Op2(11 downto 8)) & '0';
                     immidiate   := x"000000" & unsigned(Op2(7 downto 0));
                     
                     useoldcarry := '0';
                     shiftcarry  := '0';
                     if (rotateamount = 0) then
                        useoldcarry := '1';
                     else
                        shiftcarry  := immidiate(to_integer(rotateamount) - 1);
                     end if;
      
                     immidiate   := immidiate ror to_integer(rotateamount);
                  
                     decode_rdest            <= Rdest;
                     decode_Rn_op1           <= Rn_op1;
                     decode_Rn_op1_save      <= Rn_op1;
                     decode_RM_op2           <= RM_op2;
                     decode_alu_use_immi     <= use_imm;
                     decode_immidiate        <= immidiate;
                     decode_shiftcarry       <= shiftcarry;
                     decode_useoldcarry      <= useoldcarry;
                     decode_updateflags      <= updateflags;
      
                     decode_alu_use_immi     <= use_imm;
                     decode_alu_use_shift    <= not use_imm;
                  
                     if (use_imm = '0') then
                        decode_shift_regbased   <= decode_datacomb(4);
                        if (decode_datacomb(4) = '1') then -- shift by reg uses op1 -> exchanged while stall
                           decode_Rn_op1 <= decode_datacomb(11 downto 8);
                        end if;
                     end if;
                  
                     if (updateflags = '0' and unsigned(opcode) >= 8 and unsigned(opcode) <= 11) then -- PSR Transfer
                  
                        decode_psr_with_spsr    <= decode_datacomb(22); -- spsr -> reg17
                  
                        if (decode_datacomb(21 downto 16) = "001111") then 
                           decode_functions_detail <= data_processing_MRS; -- MRS (transfer PSR contents to a register)
                        else
                           decode_functions_detail <= data_processing_MSR; -- MSR (transfer register contents or immdiate value to PSR)
                        end if;
                  
                     else
                     
                        case opcode is
                           when x"0" => decode_functions_detail <= alu_and;           decode_writeback <= '1'; decode_switch_op <= '0'; --  AND 0000 operand1 AND operand2
                           when x"1" => decode_functions_detail <= alu_xor;           decode_writeback <= '1'; decode_switch_op <= '0'; --  EOR 0001 operand1 EOR operand2
                           when x"2" => decode_functions_detail <= alu_sub;           decode_writeback <= '1'; decode_switch_op <= '0'; --  SUB 0010 operand1 - operand2
                           when x"3" => decode_functions_detail <= alu_sub;           decode_writeback <= '1'; decode_switch_op <= '1'; --  RSB 0011 operand2 - operand1
                           when x"4" => decode_functions_detail <= alu_add;           decode_writeback <= '1'; decode_switch_op <= '0'; --  ADD 0100 operand1 + operand2
                           when x"5" => decode_functions_detail <= alu_add_withcarry; decode_writeback <= '1'; decode_switch_op <= '0'; --  ADC 0101 operand1 + operand2 + carry
                           when x"6" => decode_functions_detail <= alu_sub_withcarry; decode_writeback <= '1'; decode_switch_op <= '0'; --  SBC 0110 operand1 - operand2 + carry - 1
                           when x"7" => decode_functions_detail <= alu_sub_withcarry; decode_writeback <= '1'; decode_switch_op <= '1'; --  RSC 0111 operand2 - operand1 + carry - 1
                           when x"8" => decode_functions_detail <= alu_and;           decode_writeback <= '0'; decode_switch_op <= '0'; --  TST 1000 as AND, but result is not written
                           when x"9" => decode_functions_detail <= alu_xor;           decode_writeback <= '0'; decode_switch_op <= '0'; --  TEQ 1001 as EOR, but result is not written
                           when x"A" => decode_functions_detail <= alu_sub;           decode_writeback <= '0'; decode_switch_op <= '0'; --  CMP 1010 as SUB, but result is not written
                           when x"B" => decode_functions_detail <= alu_add;           decode_writeback <= '0'; decode_switch_op <= '0'; --  CMN 1011 as ADD, but result is not written
                           when x"C" => decode_functions_detail <= alu_or;            decode_writeback <= '1'; decode_switch_op <= '0'; --  ORR 1100 operand1 OR operand2
                           when x"D" => decode_functions_detail <= alu_mov;           decode_writeback <= '1'; decode_switch_op <= '0'; --  MOV 1101 operand2(operand1 is ignored)
                           when x"E" => decode_functions_detail <= alu_and_not;       decode_writeback <= '1'; decode_switch_op <= '0'; --  BIC 1110 operand1 AND NOT operand2(Bit clear)
                           when x"F" => decode_functions_detail <= alu_mov_not;       decode_writeback <= '1'; decode_switch_op <= '0'; --  MVN 1111 NOT operand2(operand1 is ignored)
                           when others => report "should never happen" severity failure; 
                        end case;
                        
                        if (Rdest = x"F" and updateflags = '1') then
                           decode_leaveirp <= '1';
                        end if;
                     
                     end if;
                     
                  when multiply | multiply_long =>
                     decode_functions_detail <= mulboth;
                     decode_rdest            <= decode_datacomb(19 downto 16);
                     decode_rdest_save       <= Rdest;
                     decode_Rn_op1           <= decode_datacomb(3 downto 0);
                     decode_Rn_op1_save      <= Rn_op1;
                     decode_RM_op2           <= decode_datacomb(11 downto 8);
                     decode_updateflags      <= decode_datacomb(20);
                     decode_mul_signed       <= decode_datacomb(22);
                     decode_mul_useadd       <= decode_datacomb(21);
                     decode_mul_long         <= '0';
                     if (decode_functions = multiply_long) then
                        decode_mul_long <= '1';
                     end if;
                     
                  when branch =>
                     decode_functions_detail <= branch_all;
                     decode_branch_link      <= decode_datacomb(24);
                     if (thumbmode = '1') then
                        decode_branch_immi   <= resize(signed(decode_datacomb(23 downto 0)), 25) & "0";
                     else
                        decode_branch_immi   <= signed(decode_datacomb(23 downto 0)) & "00";
                     end if;
                     decode_rdest            <= x"E"; -- 14
                     decode_branch_usereg    <= '0';
                     if (v5_blximm = '1') then
                        -- ARM BLX <label>: always links, always switches to
                        -- Thumb, H bit (24) becomes target bit 1
                        decode_branch_link       <= '1';
                        decode_branch_forcethumb <= '1';
                        decode_branch_immi       <= signed(decode_datacomb(23 downto 0)) & decode_data(24) & '0';
                     end if;

                  when branch_and_exchange =>
                     decode_functions_detail <= branch_all;
                     decode_set_thumbmode    <= '1';
                     decode_RM_op2           <= RM_op2;
                     decode_branch_usereg    <= '1';
                     decode_branch_link      <= '0';
                     if (thumbmode = '0' and decode_datacomb(5) = '1') then
                        decode_branch_link <= '1';       -- ARM BLX Rm: LR = PC-4
                     end if;
                     if (thumbmode = '1' and v5_blxreg = '1') then
                        -- Thumb BLX Rm: LR = (PC-2)|1, via the long-branch link path
                        decode_branch_link <= '1';
                        decode_branch_long <= '1';
                        decode_immidiate   <= (others => '0');
                     end if;
                                 
                  when single_data_transfer | halfword_data_transfer_regoffset | halfword_data_transfer_immoffset | single_data_swap => 
                     if (decode_datacomb(20) = '1') then
                        decode_functions_detail <= data_read;
                     else
                        decode_functions_detail <= data_write;
                     end if;
                     decode_RM_op2 <= RM_op2;
                     decode_Rn_op1 <= Rn_op1;
                     decode_rdest  <= Rdest;
                     
                     decode_datatransfer_preadd    <= opcode(3);
                     decode_datatransfer_addup     <= opcode(2);
                     decode_datatransfer_writeback <= (not opcode(3)) or opcode(0);
                     if (Rn_op1 = Rdest and decode_datacomb(20) = '1') then --when storing, result address can be written
                        decode_datatransfer_writeback <= '0';
                     end if;
                     
                     if (Rn_op1 = x"F") then -- for pc relative load -> word aligned
                        decode_clearbit1 <= '1';
                     end if;
                     
                     decode_datatransfer_shiftval  <= '0';
                     decode_datatransfer_regoffset <= '0';
                     decode_datatransfer_swap      <= '0';
                     decode_datatransfer_addvalue  <= (others => '0');
                     
                     if (decode_functions = single_data_transfer) then
                        decode_datatransfer_addvalue  <= unsigned(op2);
                        decode_datatransfer_shiftval  <= use_imm;
                        decode_datatransfer_regoffset <= use_imm;
                        if (opcode(1) = '1') then
                           decode_datatransfer_type <= ACCESS_8BIT;
                           decode_datareceivetype   <= RECEIVETYPE_BYTE;
                        else
                           decode_datatransfer_type <= ACCESS_32BIT;
                           decode_datareceivetype   <= RECEIVETYPE_DWORD;
                        end if;
                        
                        if (use_imm = '1') then
                           decode_shift_regbased   <= decode_datacomb(4);
                           if (decode_datacomb(4) = '1') then -- shift by reg uses op1 -> exchanged while stall
                              decode_Rn_op1 <= decode_datacomb(11 downto 8);
                           end if;
                        end if;
                        
                     elsif (decode_functions = halfword_data_transfer_regoffset or decode_functions = halfword_data_transfer_immoffset) then
                        case (decode_datacomb(6 downto 5)) is
                           when "01" => decode_datatransfer_type <= ACCESS_16BIT; decode_datareceivetype <= RECEIVETYPE_WORD;
                           when "10" => decode_datatransfer_type <= ACCESS_8BIT;  decode_datareceivetype <= RECEIVETYPE_SIGNEDBYTE;
                           when "11" => decode_datatransfer_type <= ACCESS_16BIT; decode_datareceivetype <= RECEIVETYPE_SIGNEDWORD;
                           when others => report "should never happen" severity failure;
                        end case;
                        if (decode_datacomb(20) = '0' and decode_datacomb(6) = '1') then
                           -- v5TE LDRD/STRD occupy the store encodings of the
                           -- signed transfers: (6:5)=10 -> LDRD, 11 -> STRD
                           if (decode_datacomb(5) = '0') then
                              decode_functions_detail <= data_read;
                           else
                              decode_functions_detail <= data_write;
                           end if;
                           decode_datatransfer_double <= '1';
                           decode_datatransfer_type   <= ACCESS_32BIT;
                           decode_datareceivetype     <= RECEIVETYPE_DWORD;
                        end if;
                        decode_datatransfer_addvalue <= x"0" & unsigned(decode_datacomb(11 downto 8)) & unsigned(decode_datacomb(3 downto 0));
                        if (decode_functions = halfword_data_transfer_regoffset) then
                           decode_datatransfer_regoffset <= '1';
                        end if;
                     elsif (decode_functions = single_data_swap) then
                        decode_datatransfer_writeback <= '0';
                        decode_functions_detail       <= data_read;
                        decode_datatransfer_swap      <= '1';
                        if (opcode(1) = '1') then
                           decode_datatransfer_type <= ACCESS_8BIT;
                           decode_datareceivetype   <= RECEIVETYPE_BYTE;
                        else
                           decode_datatransfer_type <= ACCESS_32BIT;
                           decode_datareceivetype   <= RECEIVETYPE_DWORD;
                        end if;
                     end if;
                  
                  when block_data_transfer  => 
                     if (decode_datacomb(20) = '1') then
                        decode_functions_detail <= block_read;
                     else
                        decode_functions_detail <= block_write;
                     end if;
                     
                     decode_Rn_op1                 <= Rn_op1;
                     decode_block_reglist          <= decode_datacomb(15 downto 0);
                     decode_blockbits              := decode_datacomb(15 downto 0);
                     decode_datatransfer_preadd    <= opcode(3);
                     decode_datatransfer_addup     <= opcode(2);
                     decode_datatransfer_writeback <= opcode(0);
                     if (decode_datacomb(to_integer(unsigned(Rn_op1))) = '1' and decode_datacomb(20) = '1') then -- writeback in reglist and load
                        decode_datatransfer_writeback <= '0';
                     end if;
                     if (decode_blockbits = x"0000") then -- reglist empty
                        decode_block_reglist(15) <= '1';
                        decode_block_emptylist   <= '1';
                     else
                        decode_block_emptylist   <= '0';
                     end if;
                     
                     decode_block_usermoderegs <= '0';
                     decode_block_switchmode   <= '0';
                     if (opcode(1) = '1') then
                        if ((decode_datacomb(15) = '1' and decode_datacomb(20) = '0') or (decode_datacomb(15) = '0')) then
                           decode_block_usermoderegs <= '1';
                        end if;
                        if (decode_datacomb(15) = '1' and decode_datacomb(20) = '1') then
                           decode_block_switchmode <= '1';
                        end if;
                     end if;
                     
                     decode_block_addrmod <= 0;
                     decode_block_endmod  <= 0;
                     if (opcode(2) = '0') then -- down
                        if (decode_blockbits = x"0000") then -- reglist empty
                           decode_block_endmod  <= -64;
                           decode_block_addrmod <= -64;
                           if (opcode(3) = '0') then -- not pre
                              decode_block_addrmod <= -60;
                           end if;
                        else
                           decode_block_endmod <= (-4) * (bitcount8_low + bitcount8_high);
                           if (opcode(3) = '0') then -- not pre
                              decode_block_addrmod <= ((-4) * (bitcount8_low + bitcount8_high)) + 4;
                           else
                              decode_block_addrmod <= (-4) * (bitcount8_low + bitcount8_high);
                           end if;
                           decode_block_addrmod_baseRlist <= (-4) * (bitcount8_low + bitcount8_high);
                        end if;
                     elsif (opcode(3) = '1') then -- pre
                        decode_block_addrmod <= 4;
                     end if;
                     if (opcode(2) = '1') then --up
                        decode_block_addrmod_baseRlist <= 4 * (bitcount8_low + bitcount8_high);
                        decode_block_endmod <= 4 * (bitcount8_low + bitcount8_high);
                        if (decode_blockbits = x"0000") then -- empty list
                           decode_block_endmod <= 64;
                        end if;
                     end if;
                     
                     decode_RM_op2 <= x"F";
                     for i in 15 downto 0 loop
                        if (decode_blockbits(i) = '1') then 
                           decode_RM_op2 <= std_logic_vector(to_unsigned(i,4));
                        end if;
                     end loop;
                     
                     
                     
                  when software_interrupt => 
                     decode_functions_detail <= software_interrupt_detail;
                     decode_rdest            <= x"E"; -- 14
               
                  -- thumb
      
                  when long_branch_with_link =>
                     if (decode_datacomb(11) = '0') then
                        decode_functions_detail <= alu_add;
                        decode_writeback        <= '1';
                        decode_rdest            <= x"E";
                        decode_Rn_op1           <= x"F";
                        decode_alu_use_immi     <= '1';
                        decode_updateflags      <= '0';
                        decode_immidiate        <= unsigned(resize(signed(decode_datacomb(10 downto 0)), 20)) & x"000";
                     else
                        decode_functions_detail <= branch_all;
                        decode_RM_op2           <= x"E";
                        decode_immidiate        <= x"00000" & "0" & unsigned(decode_datacomb(10 downto 0));
                        decode_branch_long      <= '1';
                        decode_branch_link      <= '1';
                        if (v5_blxreg = '1') then
                           decode_branch_forcearm <= '1'; -- Thumb BLX suffix returns to ARM
                        end if;
                     end if;

                  -- ================= v5TE additions =================

                  when v5_misc =>
                     decode_updateflags <= '0';
                     if (decode_datacomb(7 downto 4) = x"1") then
                        -- CLZ Rd, Rm
                        decode_functions_detail <= alu_clz;
                        decode_rdest  <= Rdest;
                        decode_RM_op2 <= RM_op2;
                     elsif (decode_datacomb(7 downto 4) = x"5") then
                        -- QADD/QSUB/QDADD/QDSUB Rd, Rm, Rn
                        decode_functions_detail <= sat_arith;
                        decode_rdest      <= Rdest;
                        decode_RM_op2     <= RM_op2;            -- Rm
                        decode_Rn_op1     <= Rn_op1;            -- Rn (doubled operand)
                        decode_sat_sub    <= decode_datacomb(21);
                        decode_sat_double <= decode_datacomb(22);
                     else
                        -- SMULxy/SMLAxy/SMULWy/SMLAWy/SMLALxy
                        -- first beat multiplies Rm (op2) by Rs (op1); the
                        -- accumulate beats swap op1 to Rn/RdLo then RdHi via
                        -- the same decode-swap idiom the MUL path uses
                        decode_functions_detail <= mul_dsp;
                        decode_rdest       <= Rn_op1;                       -- Rd / RdHi (19:16)
                        decode_RM_op2      <= RM_op2;                       -- Rm
                        decode_Rn_op1      <= decode_datacomb(11 downto 8); -- Rs
                        decode_Rn_op1_save <= Rdest;                        -- Rn acc / RdLo (15:12)
                        decode_dsp_acchi   <= Rn_op1;                       -- RdHi for the long high beat
                        decode_dsp_x       <= decode_datacomb(5);
                        decode_dsp_y       <= decode_datacomb(6);
                        decode_dsp_acc     <= '0';
                        decode_dsp_long    <= '0';
                        decode_dsp_word    <= '0';
                        case decode_datacomb(22 downto 21) is
                           when "00"   => decode_dsp_acc  <= '1';                      -- SMLAxy
                           when "01"   => decode_dsp_word <= '1';                      -- SMLAWy/SMULWy
                                          decode_dsp_acc  <= not decode_datacomb(5);
                           when "10"   => decode_dsp_long <= '1';                      -- SMLALxy
                                          decode_dsp_acc  <= '1';
                           when others => null;                                        -- "11" SMULxy
                        end case;
                     end if;

                  when coprocessor_op =>
                     decode_functions_detail <= cp15_op;
                     decode_updateflags <= '0';
                     decode_rdest       <= Rdest;
                     decode_cp15_mrc    <= decode_datacomb(20);
                     decode_cp15_crn    <= Rn_op1;
                     decode_cp15_crm    <= RM_op2;
                     decode_cp15_op2    <= decode_datacomb(7 downto 5);
                     if (decode_datacomb(11 downto 8) /= x"F" or decode_datacomb(23 downto 21) /= "000") then
                        decode_functions_detail <= nop_detail; -- only p15 with opcode1=0 exists
                     end if;

                  when v5_nop =>
                     decode_functions_detail <= nop_detail;
                     decode_updateflags <= '0';

               end case;
               
            end if; -- update decode
            
            if (IRQ_in = '1' and IRQ_disable = '0' and (busState /= BUSSTATE_WAITFETCH or gb_bus_done = '1') and (decode_functions_detail /= IRQ or execute_now = '0')) then
               if (decode_unhalt = '1') then
                  decode_ready  <= '1';
               end if;
               if (decode_unhalt = '1' or execute_done = '1' or (execute_now = '0' and execute_stall = '0')) then
                  decode_functions_detail <= IRQ;
                  decode_condition        <= x"E";
                  decode_rdest            <= x"E";
                  -- On a halt wake-up a valid pending instruction is already
                  -- decoded and its decode_PC is the correct return anchor —
                  -- fetch_PC has run one fetch further ahead and must not
                  -- clobber it (the GBA core takes fetch_PC here, which makes
                  -- the IRQ return skip the first instruction after a
                  -- wait-for-interrupt).
                  if (decode_unhalt = '1') then
                     if (decode_ready = '0') then
                        decode_PC <= fetch_PC;
                     end if;
                  elsif (fetch_done = '1') then
                     decode_PC <= fetch_PC;
                  end if;
               end if;
            end if;
            
            if (execute_branch = '1') then
               decode_ready <= '0';
            end if;
         
         end if; -- ce
         
      end if; -- clk
   
   end process;
   
   
   -- Execute
   
   -- fetch OPs
   process (all)
   begin
      if (decode_Rn_op1 = x"F") then
         if (execute_stall = '1') then
            execute_op1 <= fetch_PC;
         else
            execute_op1 <= decode_PC;
         end if;
      else
         execute_op1 <= regs(to_integer(unsigned(decode_Rn_op1)));
      end if;
      if (decode_clearbit1 = '1') then
         execute_op1(1) <= '0';
      end if;
      
      if (decode_alu_use_immi = '1') then
         execute_op2 <= decode_immidiate;
      elsif  (decode_RM_op2 = x"F") then
         if (execute_stall = '1' or decode_functions_detail = block_write) then
            execute_op2 <= fetch_PC;
         else
            execute_op2 <= decode_PC;
         end if;
      else
         execute_op2  <= regs(to_integer(unsigned(decode_RM_op2)));
      end if;
      
      if (decode_rdest = x"F") then
         if (execute_stall = '1') then
            execute_opDest <= fetch_PC;
         else
            execute_opDest <= decode_PC;
         end if;
      else
         execute_opDest <= regs(to_integer(unsigned(decode_rdest)));
      end if;

   end process;
   
   -- ================= shifter =================
   -- One rotator, not five shifters.
   --
   -- This used to build a full 32-bit barrel shifter per mode (LSL, LSR, ASR,
   -- ROR, plus the trivial RRX) and mux the five results. Worse, the amount is
   -- declared `integer range 0 to 255` - a register-specified shift may name any
   -- Rs[7:0] - and Quartus sizes a variable shifter from the DECLARED range, not
   -- the reachable one, so each was EIGHT stages deep even though every branch
   -- using it is guarded by `< 32`. The three extra stages can only shift by 32,
   -- 64 or 128, i.e. produce zero. Same for the `shiftervalue(amount - 1)` carry
   -- picks: four 256-entry muxes to select one of 32 bits.
   --
   -- On the worst path that showed up as a 5.95 ns "shifter tail" with 4.38 ns
   -- of it interconnect - the signature of a block too large to place compactly,
   -- not of deep logic.
   --
   -- Every ARM shift is a right-rotate plus an edge fill:
   --
   --   LSL n  = (v ror (32-n)) with bits [n-1:0]  := 0
   --   LSR n  = (v ror n)      with bits [31:32-n] := 0
   --   ASR n  = (v ror n)      with bits [31:32-n] := v(31)
   --   ROR n  = (v ror n)
   --   RRX    = (v ror 1)      with bit 31         := C
   --
   -- so the operand crosses one 5-stage rotator and one keep/fill mux. The
   -- rotate amount, the keep mask, which fill to use and which bit the carry
   -- comes from are all functions of decode_shift_amount / decode_shift_mode /
   -- decode_shift_RRX - registers, every one - so none of that decode sits on
   -- the operand path at all.
   shiftervalue <= execute_op2;

   process (all)
      variable n : integer range 0 to 255;
   begin
      n       := decode_shift_amount;

      sh_rot  <= 0;
      sh_keep <= (others => '1');
      sh_fill <= FILL_ZERO;
      sh_cidx <= 0;
      sh_csel <= CSEL_CARRY;         -- amount 0 leaves C untouched, all modes

      if (decode_shift_RRX = '1') then
         sh_rot  <= 1;
         sh_keep <= (31 => '0', others => '1');
         sh_fill <= FILL_CARRY;
         sh_csel <= CSEL_VALUE;
         sh_cidx <= 0;               -- carry out = v(0)

      elsif (n /= 0) then
         case (decode_shift_mode) is

            when "00" =>                                  -- LSL
               if (n < 32) then
                  sh_rot  <= 32 - n;
                  for i in 0 to 31 loop
                     if (i < n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_csel <= CSEL_VALUE;
                  sh_cidx <= 32 - n;
               else
                  sh_keep <= (others => '0');
                  -- LSL #32 shifts bit 0 out; beyond that the carry is clear
                  if (n = 32) then
                     sh_csel <= CSEL_VALUE;
                     sh_cidx <= 0;
                  else
                     sh_csel <= CSEL_ZERO;
                  end if;
               end if;

            when "01" =>                                  -- LSR
               if (n < 32) then
                  sh_rot  <= n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_csel <= CSEL_VALUE;
                  sh_cidx <= n - 1;
               else
                  sh_keep <= (others => '0');
                  if (n = 32) then
                     sh_csel <= CSEL_VALUE;
                     sh_cidx <= 31;
                  else
                     sh_csel <= CSEL_ZERO;
                  end if;
               end if;

            when "10" =>                                  -- ASR
               -- saturates: >= 32 is the sign in every bit, carry = sign
               sh_fill <= FILL_SIGN;
               sh_csel <= CSEL_VALUE;
               if (n < 32) then
                  sh_rot  <= n;
                  for i in 0 to 31 loop
                     if (i > 31 - n) then sh_keep(i) <= '0'; end if;
                  end loop;
                  sh_cidx <= n - 1;
               else
                  sh_keep <= (others => '0');
                  sh_cidx <= 31;
               end if;

            when others =>                                -- ROR
               -- decode already folds a register amount > 32 down to Rs[4:0] or
               -- to exactly 32, so >= 32 here means ROR #32: value unchanged,
               -- carry = bit 31.
               sh_csel <= CSEL_VALUE;
               if (n < 32) then
                  sh_rot  <= n;
                  sh_cidx <= n - 1;
               else
                  sh_rot  <= 0;
                  sh_cidx <= 31;
               end if;

         end case;
      end if;
   end process;

   sh_rotv  <= shiftervalue ror sh_rot;
   sh_fillb <= Flag_Carry       when sh_fill = FILL_CARRY else
               shiftervalue(31) when sh_fill = FILL_SIGN  else '0';

   gshiftbit : for i in 0 to 31 generate
      shiftresult(i) <= sh_rotv(i) when sh_keep(i) = '1' else sh_fillb;
   end generate;

   shiftercarry <= Flag_Carry            when sh_csel = CSEL_CARRY else
                   shiftervalue(sh_cidx) when sh_csel = CSEL_VALUE else '0';
   
   -- ALU
   alu_op1 <= shiftresult when (decode_switch_op = '1' and decode_alu_use_shift = '1') else
              execute_op2 when (decode_switch_op = '1' and decode_alu_use_shift = '0') else
              execute_op1;
   
   alu_op2 <= shiftresult when (decode_switch_op = '0' and decode_alu_use_shift = '1') else
              execute_op2 when (decode_switch_op = '0' and decode_alu_use_shift = '0') else
              execute_op1;
   
   -- ADC/SBC used to write their carry-in as a *second* arithmetic operation
   -- chained onto the first ("A+B then +1", "A-B then -1"), because the carry
   -- appeared as a separate term inside an if/else. Quartus shared the common
   -- A+B and hung an incrementer off it, so the operand path ran through two
   -- 32-bit carry chains in series: `Add22 -> Add24` in the worst-path report,
   -- 4.74 ns of the 21.8 ns `decode_RM_op2 -> vram_din` path. Folding the carry
   -- into a single sum puts it in the chain's own carry-in and leaves one chain.
   --
   --   ADC: A + B + C                     (C as the adder carry-in)
   --   SBC: A + not B + C  ==  A - B - (1-C)
   --
   -- Both are exact rewrites, not approximations: SBC with C=1 is A-B and with
   -- C=0 is A-B-1, which is what the if/else spelled out.
   --
   -- Writing that literally as `A + B + C` does NOT work, and this comment used
   -- to claim it would. Quartus treats the third operand as a full-width term
   -- and builds a ternary adder - two chained carry chains, exactly what the
   -- if/else produced. Measured: `Add22 -> Add24` still in series on the worst
   -- path afterwards, and the Add24 count went *up* (668 -> 1012).
   --
   -- The form below appends the carry as an extra LSB so it rides the one
   -- chain, then drops that bit:
   --
   --   (2A + 1) + (2B + C)  =  2(A + B) + 1 + C,  bits [n:1] = A + B + C
   --
   -- since floor((1+C)/2) is C for C in {0,1}. SBC's 33-bit sum can wrap, which
   -- is harmless: dropping a multiple of 2^33 before the shift drops a multiple
   -- of 2^32 after it, and the result is taken mod 2^32 anyway. ADC's 34-bit
   -- sum cannot wrap (max 2^34-2), so bit 33 is a true carry-out and lands on
   -- alu_result_add(32), which is what the flag logic reads.
   process (all)
      variable adc_wide : unsigned(33 downto 0);
      variable sbc_wide : unsigned(32 downto 0);
   begin
      adc_wide := ('0' & alu_op1 & '1') + ('0' & alu_op2 & Flag_Carry);
      sbc_wide := (alu_op1 & '1') + ((not alu_op2) & Flag_Carry);
      alu_result     <= (others => '0');
      alu_result_add <= (others => '0');
      case (decode_functions_detail) is
         when alu_and =>     alu_result <= alu_op1 and alu_op2;          
         when alu_xor =>     alu_result <= alu_op1 xor alu_op2;       
         when alu_or  =>     alu_result <= alu_op1  or alu_op2;         
         when alu_and_not => alu_result <= alu_op1 and (not alu_op2);                                     
         when alu_mov =>     alu_result <= alu_op2;                      
         when alu_mov_not => alu_result <= not alu_op2;                  
            
         when alu_add => 
            alu_result_add <= ('0' & alu_op1) + ('0' & alu_op2);
            alu_result <= alu_result_add(31 downto 0);
         
         when alu_sub => 
            alu_result <= alu_op1 - alu_op2;
         
         when alu_add_withcarry =>
            alu_result_add <= adc_wide(33 downto 1);
            alu_result <= alu_result_add(31 downto 0);

         when alu_sub_withcarry =>
            alu_result <= sbc_wide(32 downto 1);
 
         when others => null;
      end case;
      
      execute_flag_Carry      <= Flag_Carry;
      execute_flag_Zero       <= Flag_Zero;
      execute_flag_Negative   <= Flag_Negative;
      execute_flag_V_Overflow <= Flag_V_Overflow;
      
      if (decode_alu_use_shift = '1') then
         alu_shiftercarry <= shiftercarry;
      elsif (decode_useoldcarry = '1') then
         alu_shiftercarry <= Flag_Carry;
      else
         alu_shiftercarry <= decode_shiftcarry;
      end if;
      

      
      if (decode_updateflags = '1' and (execute_skip = '0' or execute_stall = '1')) then
                        
         case (decode_functions_detail) is
            when alu_and =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_xor =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_or  =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_and_not => execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);                                 
            when alu_mov =>     execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            when alu_mov_not => execute_flag_Carry <= alu_shiftercarry; if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; execute_flag_Negative <= alu_result(31);
            
            when alu_add | alu_add_withcarry =>  
               if (alu_result_add(31 downto 0) = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
               execute_flag_Negative <= alu_result_add(31);
               execute_flag_Carry <= alu_result_add(32);
               if ((alu_op1(31) xor alu_result_add(31)) = '1' and (alu_op2(31) xor alu_result_add(31)) = '1') then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;
            
            when alu_sub => 
               if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; 
               execute_flag_Negative <= alu_result(31);
               if (alu_op1(31) /= alu_op2(31) and alu_op1(31) /= alu_result(31)) then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;
               if (alu_op1 >= alu_op2) then -- subs -> carry is 0 if borror, 1 otherwise
                  execute_flag_Carry <= '1'; 
               else
                  execute_flag_Carry <= '0'; 
               end if;
            
            when alu_sub_withcarry =>
               if (alu_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if; 
               execute_flag_Negative <= alu_result(31);
               if (alu_op1(31) /= alu_op2(31) and alu_op1(31) /= alu_result(31)) then
                  execute_flag_V_Overflow <= '1';
               else
                  execute_flag_V_Overflow <= '0';
               end if;
               if (Flag_Carry = '1') then
                  if (alu_op1 >= alu_op2) then
                     execute_flag_Carry <= '1'; 
                  else
                     execute_flag_Carry <= '0'; 
                  end if;
               else
                  if (alu_op1 = 0) then
                     execute_flag_Carry <= '0'; 
                  elsif ((alu_op1 - 1) >= alu_op2) then
                     execute_flag_Carry <= '1'; 
                  else
                     execute_flag_Carry <= '0'; 
                  end if;
               end if;
         
            when mulboth =>
               if (decode_mul_long = '1') then
                  if (execute_mul_result = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
                  execute_flag_Negative <= execute_mul_result(63);
               else
                  if (execute_mul_result(31 downto 0) = 0) then execute_flag_Zero <= '1'; else execute_flag_Zero <= '0'; end if;
                  execute_flag_Negative <= execute_mul_result(31);
               end if;
         
            when others => null;
         end case;
      end if;
      
   end process;
   
   
   -- ================= v5TE helpers =================

   -- CLZ
   process (all)
      variable found : boolean;
      variable cnt   : integer range 0 to 32;
   begin
      found := false;
      cnt   := 32;
      for i in 31 downto 0 loop
         if (not found and execute_op2(i) = '1') then
            cnt   := 31 - i;
            found := true;
         end if;
      end loop;
      execute_clz_result <= to_unsigned(cnt, 32);
   end process;

   -- QADD/QSUB/QDADD/QDSUB: op2 = Rm, op1 = Rn (the doubled operand)
   process (all)
      variable dbl    : signed(32 downto 0);
      variable dblsat : signed(31 downto 0);
      variable sum    : signed(32 downto 0);
      variable qflag  : std_logic;
   begin
      qflag := '0';

      if (decode_sat_double = '1') then
         dbl := resize(signed(execute_op1), 33) + resize(signed(execute_op1), 33);
      else
         dbl := resize(signed(execute_op1), 33);
      end if;
      if (dbl > to_signed(2147483647, 33)) then
         dblsat := x"7FFFFFFF";
         qflag  := '1';
      elsif (dbl < to_signed(-2147483648, 33)) then
         dblsat := x"80000000";
         qflag  := '1';
      else
         dblsat := dbl(31 downto 0);
      end if;

      if (decode_sat_sub = '1') then
         sum := resize(signed(execute_op2), 33) - resize(dblsat, 33);
      else
         sum := resize(signed(execute_op2), 33) + resize(dblsat, 33);
      end if;
      if (sum > to_signed(2147483647, 33)) then
         execute_sat_result <= x"7FFFFFFF";
         qflag := '1';
      elsif (sum < to_signed(-2147483648, 33)) then
         execute_sat_result <= x"80000000";
         qflag := '1';
      else
         execute_sat_result <= unsigned(sum(31 downto 0));
      end if;
      execute_sat_qset <= qflag;
   end process;

   -- DSP multiply accumulate beat: product low + current op1 (Rn/RdLo),
   -- with signed-overflow detection for the Q flag (SMLAxy/SMLAWy)
   process (all)
      variable p : unsigned(31 downto 0);
      variable s : unsigned(31 downto 0);
   begin
      p := execute_mul_result(31 downto 0);
      if (decode_dsp_acc = '1') then
         s := p + execute_op1;
      else
         s := p;
      end if;
      execute_dsp_sum <= s;
      if (decode_dsp_acc = '1' and decode_dsp_long = '0' and
          p(31) = execute_op1(31) and s(31) /= p(31)) then
         execute_dsp_qset <= '1';
      else
         execute_dsp_qset <= '0';
      end if;
   end process;

   -- CP15 read data
   process (all)
   begin
      cp15_rdata <= (others => '0');
      case (decode_cp15_crn) is
         when x"0" =>
            case (decode_cp15_op2) is
               when "001"  => cp15_rdata <= x"0F0D2112"; -- cache type
               when "010"  => cp15_rdata <= x"00140180"; -- TCM size
               when others => cp15_rdata <= x"41059461"; -- main ID: ARM946E-S rev 1
            end case;
         when x"1" => cp15_rdata <= cp15_control;
         when x"2" =>
            if (decode_cp15_op2 = "001") then
               cp15_rdata <= cp15_pu_icache;
            else
               cp15_rdata <= cp15_pu_dcache;
            end if;
         when x"3" => cp15_rdata <= cp15_pu_wbuf;
         when x"5" =>
            if (decode_cp15_op2(0) = '1') then
               cp15_rdata <= cp15_pu_iperm;
            else
               cp15_rdata <= cp15_pu_dperm;
            end if;
         when x"6" => cp15_rdata <= cp15_pu_region(to_integer(unsigned(decode_cp15_crm(2 downto 0))));
         when x"9" =>
            if (decode_cp15_crm = x"1") then
               if (decode_cp15_op2 = "001") then
                  cp15_rdata <= cp15_itcm_reg;
               else
                  cp15_rdata <= cp15_dtcm_reg;
               end if;
            else
               if (decode_cp15_op2 = "001") then
                  cp15_rdata <= cp15_icache_lock;
               else
                  cp15_rdata <= cp15_dcache_lock;
               end if;
            end if;
         when x"D" => cp15_rdata <= cp15_trace_pid;
         when others => null;
      end case;
   end process;

   -- MCR p15, 0, Rd, c7, c0, 4: wait for interrupt
   execute_wfi <= '1' when (decode_functions_detail = cp15_op and execute_now = '1' and execute_skip = '0' and
                            decode_cp15_mrc = '0' and decode_cp15_crn = x"7" and
                            decode_cp15_crm = x"0" and decode_cp15_op2 = "100") else '0';

   -- MCR c7 ops that go to nds_cache9 (and therefore stall until it finishes)
   execute_cp15_cacheop <=
      '1' when (decode_cp15_mrc = '0' and decode_cp15_crn = x"7" and
                ((decode_cp15_crm = x"5" and (decode_cp15_op2 = "000" or decode_cp15_op2 = "001")) or
                 (decode_cp15_crm = x"6" and (decode_cp15_op2 = "000" or decode_cp15_op2 = "001" or decode_cp15_op2 = "010")) or
                 (decode_cp15_crm = x"A" and (decode_cp15_op2 = "001" or decode_cp15_op2 = "010")) or
                 (decode_cp15_crm = x"E" and (decode_cp15_op2 = "001" or decode_cp15_op2 = "010")))) else '0';

   -- data read/write
   execute_blockRW_last <= '1' when (decode_block_reglist = x"0000") else '0';
   
   process (all)
   begin
      
      execute_RW_data <= (others => '0');
      execute_RW_addr <= (others => '0');
      execute_RW_rnw  <= '1';
      execute_RW_acc  <= "10";
      execute_RW_ena  <= '0';
      
      execute_busaddress <= execute_op1;

      bus_lowbits <= "00";
      
      -- normal RW
      if (decode_datatransfer_shiftval = '1') then
         execute_busaddmod <= shiftresult;
      elsif (decode_datatransfer_regoffset = '1') then
         execute_busaddmod <= execute_op2;
      else
         execute_busaddmod <= x"00000" & decode_datatransfer_addvalue;
      end if;
      
      if (decode_functions_detail = data_read or decode_functions_detail = data_write) then
         execute_RW_acc <= decode_datatransfer_type;
         if (decode_datatransfer_swap = '1') then
            execute_RW_data <= std_logic_vector(execute_op2);
         elsif (decode_rdest = x"F") then  -- pc is + 12 for data writes
            execute_RW_data <= std_logic_vector(fetch_PC);  
         else
            execute_RW_data <= std_logic_vector(execute_opDest);
         end if;
         
         if (decode_datatransfer_preadd = '1') then
            if (decode_datatransfer_addup = '1') then
               execute_RW_addr <= execute_busaddress + execute_busaddmod;
            else
               execute_RW_addr <= execute_busaddress - execute_busaddmod;
            end if;
         else
            execute_RW_addr <= execute_busaddress;
         end if;
         
         if (execute_RW_State = DATARW_IDLE) then
            execute_RW_ena <= execute_now and (not execute_skip); 
            if (decode_functions_detail = data_write) then
               execute_RW_rnw <= '0';
            end if;
         end if;
         
         if (execute_RW_State = DATARW_READSTART and decode_datatransfer_swap = '1') then
            if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
               execute_RW_ena <= '1';
               execute_RW_rnw <= '0';
            end if;
         end if;

         -- v5TE LDRD/STRD: issue the second word at addr+4 as soon as the
         -- first beat completes
         if (decode_datatransfer_double = '1' and busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
            if (execute_RW_State = DATARW_READSTART) then
               execute_RW_ena  <= '1';
               execute_RW_addr <= execute_RW_addr_last + 4;
            elsif (execute_RW_State = DATARW_WRITE) then
               execute_RW_ena  <= '1';
               execute_RW_rnw  <= '0';
               execute_RW_addr <= execute_RW_addr_last + 4;
               execute_RW_data <= std_logic_vector(regs(to_integer(unsigned(decode_rdest) + 1)));
            end if;
         end if;

      end if;
      
      -- block RW
      if (decode_functions_detail = block_read or decode_functions_detail = block_write) then
         execute_RW_data <= std_logic_vector(execute_op2);
         
         -- USER-BANK REDIRECT for ldm^/stm^. r8-r12 are banked ONLY in FIQ;
         -- r13/r14 are banked in every privileged mode. This register file is
         -- SWAP-based - regs() is the live view and regs_0_8..12 are backing
         -- store that only means anything while in FIQ (see the FIQ-entry swap
         -- below) - so redirecting r8-r12 to regs_0_* from, say, Supervisor
         -- writes storage nothing reads and the live r8-r12 keep stale values.
         -- Same bug and same fix as gba_cpu.vhd, where it broke firmware boot;
         -- see sim/tests/arm7_ctxrestore for the ARM7 reproduction.
         if (decode_block_usermoderegs = '1' and cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM and
             ((unsigned(decode_RM_op2) >= 13 and unsigned(decode_RM_op2) <= 14) or
              (unsigned(decode_RM_op2) >= 8  and unsigned(decode_RM_op2) <= 12 and cpu_mode = CPUMODE_FIQ))) then
            case (to_integer(unsigned(decode_RM_op2))) is
               when 8  => execute_RW_data <= std_logic_vector(regs_0_8);
               when 9  => execute_RW_data <= std_logic_vector(regs_0_9);
               when 10 => execute_RW_data <= std_logic_vector(regs_0_10);
               when 11 => execute_RW_data <= std_logic_vector(regs_0_11);
               when 12 => execute_RW_data <= std_logic_vector(regs_0_12);
               when 13 => execute_RW_data <= std_logic_vector(regs_0_13);
               when 14 => execute_RW_data <= std_logic_vector(regs_0_14);
               when others => null;
            end case;
         end if;
         
         if (execute_stall = '1' and decode_RM_op2 = decode_Rn_op1) then
            execute_RW_data <= std_logic_vector(execute_blockRW_endaddr);
         end if;
         
         if (execute_stall = '0') then
            execute_RW_ena  <= execute_now and (not execute_skip); 
            execute_RW_addr <= unsigned(signed(execute_busaddress) + decode_block_addrmod);
         else
            execute_RW_addr <= execute_blockRW_addr;
            if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
               execute_RW_ena <= not execute_blockRW_last;
            end if;
         end if; 
         bus_lowbits <= std_logic_vector(execute_op1(1 downto 0));
         execute_RW_addr(1 downto 0) <= "00";
           
         if (decode_functions_detail = block_write) then
            execute_RW_rnw <= '0';
         end if;
      end if;

   end process;
   
   -- MSR
   process (all)
   begin
   
      if (decode_alu_use_immi = '1') then
         execute_msr_fetchvalue <= decode_immidiate;
      else
         execute_msr_fetchvalue <= execute_op2;
      end if;
      
      execute_msr_writevalue <= SPSR;
      if (decode_Rn_op1(0) = '1') then execute_msr_writevalue( 7 downto  0) <= execute_msr_fetchvalue( 7 downto  0); end if;
      if (decode_Rn_op1(1) = '1') then execute_msr_writevalue(15 downto  8) <= execute_msr_fetchvalue(15 downto  8); end if;
      if (decode_Rn_op1(2) = '1') then execute_msr_writevalue(23 downto 16) <= execute_msr_fetchvalue(23 downto 16); end if;
      if (decode_Rn_op1(3) = '1') then execute_msr_writevalue(31 downto 24) <= execute_msr_fetchvalue(31 downto 24); end if;
   
   
      execute_switchmode_now   <= '0';
      execute_switchmode_state <= '0';
      execute_msr_setvalue     <= CPSR;
      execute_msr_setvalue_ena <= '0';
      execute_switchmode_val   <= std_logic_vector(execute_msr_setvalue(3 downto 0));
      
      if (decode_functions_detail = data_processing_MSR) then
      
         if (decode_psr_with_spsr = '0') then -- cpsr only
            execute_msr_setvalue_ena <= execute_now;
            if (cpu_mode /= CPUMODE_USER) then
               if (decode_Rn_op1(0) = '1') then execute_msr_setvalue( 7 downto  0) <= execute_msr_fetchvalue( 7 downto  0); execute_switchmode_now <= execute_now; end if;
               if (decode_Rn_op1(1) = '1') then execute_msr_setvalue(15 downto  8) <= execute_msr_fetchvalue(15 downto  8); end if;
               if (decode_Rn_op1(2) = '1') then execute_msr_setvalue(23 downto 16) <= execute_msr_fetchvalue(23 downto 16); end if;
            end if;
            if (decode_Rn_op1(3) = '1') then execute_msr_setvalue(31 downto 24) <= execute_msr_fetchvalue(31 downto 24); end if;
         end if;
         
         if (execute_now = '0' or execute_skip = '1') then
            execute_msr_setvalue_ena <= '0';
            execute_switchmode_now   <= '0';
         end if;
      
      end if;
      
      if (decode_leaveirp = '1') then
         if (decode_alu_use_shift = '0' or decode_shift_regbased = '0' or execute_stall = '1') then
            if (cpu_mode = CPUMODE_USER or cpu_mode = CPUMODE_SYSTEM) then
               execute_switchmode_now   <= '1';
               execute_switchmode_val   <= cpu_mode;
            else
               execute_switchmode_now   <= '1';
               execute_switchmode_val   <= std_logic_vector(SPSR(3 downto 0));
               execute_msr_setvalue     <= SPSR;
               execute_msr_setvalue_ena <= '1';
            end if;
         end if;
         
         if (execute_stall = '0' and (execute_now = '0' or execute_skip = '1')) then
            execute_msr_setvalue_ena <= '0';
         end if;
         
      end if;
      
      -- ldm^ with pc (exception return): CPSR := SPSR + bank swap in the
      -- dedicated DATARW_BLOCKSWITCH cycle - after the base writeback, so
      -- "ldmia sp!, {..., pc}^" leaves the OLD mode's sp updated (calico's
      -- ARM9 IRQ exit; same ordering melonDS 0.9.5 got wrong)
      if (decode_functions_detail = block_read and decode_block_switchmode = '1' and
          execute_RW_State = DATARW_BLOCKSWITCH) then
         execute_switchmode_now   <= '1';
         execute_switchmode_val   <= std_logic_vector(SPSR(3 downto 0));
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= '1';
      end if;

      if (decode_functions_detail = IRQ) then
         execute_switchmode_now   <= execute_now;
         execute_switchmode_state <= '1';
         execute_switchmode_val   <= CPUMODE_IRQ;
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= execute_now;
      end if;
      
      if (decode_functions_detail = software_interrupt_detail) then
         execute_switchmode_now   <= execute_now and not execute_skip;
         execute_switchmode_state <= '1';
         execute_switchmode_val   <= CPUMODE_SUPERVISOR;
         execute_msr_setvalue     <= SPSR;
         execute_msr_setvalue_ena <= execute_now and not execute_skip;
      end if;
      
   end process;
   
   execute_switchmode_new <= execute_switchmode_val when (execute_switchmode_val = CPUMODE_FIQ        or execute_switchmode_val = CPUMODE_IRQ   or execute_switchmode_val = CPUMODE_SUPERVISOR or
                                                          execute_switchmode_val = CPUMODE_SUPERVISOR or execute_switchmode_val = CPUMODE_ABORT or execute_switchmode_val = CPUMODE_UNDEFINED or
                                                          execute_switchmode_val = CPUMODE_SYSTEM) else CPUMODE_USER;
   
   -- condition
   process (all)
   begin
      execute_skip <= '1';
      case (decode_condition) is
         when x"0" => if (Flag_Zero = '1')                                        then execute_skip <= '0'; end if;
         when x"1" => if (Flag_Zero = '0')                                        then execute_skip <= '0'; end if;
         when x"2" => if (Flag_Carry = '1')                                       then execute_skip <= '0'; end if;
         when x"3" => if (Flag_Carry = '0')                                       then execute_skip <= '0'; end if;
         when x"4" => if (Flag_Negative = '1')                                    then execute_skip <= '0'; end if;
         when x"5" => if (Flag_Negative = '0')                                    then execute_skip <= '0'; end if;
         when x"6" => if (Flag_V_Overflow = '1')                                  then execute_skip <= '0'; end if;
         when x"7" => if (Flag_V_Overflow = '0')                                  then execute_skip <= '0'; end if;
         when x"8" => if (Flag_Carry = '1' and Flag_Zero = '0')                   then execute_skip <= '0'; end if;
         when x"9" => if (Flag_Carry = '0' or Flag_Zero = '1')                    then execute_skip <= '0'; end if;
         when x"A" => if (Flag_Negative = Flag_V_Overflow)                        then execute_skip <= '0'; end if;
         when x"B" => if (Flag_Negative /= Flag_V_Overflow)                       then execute_skip <= '0'; end if;
         when x"C" => if (Flag_Zero = '0' and (Flag_Negative = Flag_V_Overflow))  then execute_skip <= '0'; end if;
         when x"D" => if (Flag_Zero = '1' or (Flag_Negative /= Flag_V_Overflow))  then execute_skip <= '0'; end if;
         when x"E" => execute_skip <= '0';
         when others => null;
      end case;
   end process;
   
   -- outputs   
   execute_now      <= ce when (fetch_done = '1' and decode_ready = '1' and decode_halt = '0' and execute_stall = '0') else 
                       '0';
   
   execute_branch   <= '1'                                  when (execute_writeback = '1' and execute_writereg = x"F") else 
                       (execute_now and (not execute_skip)) when (decode_functions_detail = branch_all or decode_functions_detail = IRQ or decode_functions_detail = software_interrupt_detail) else 
                       '0';
   
   execute_nextIsthumb <= '0'                     when (execute_now = '1' and execute_skip = '0' and (decode_functions_detail = IRQ or decode_functions_detail = software_interrupt_detail)) else
                          execute_msr_setvalue(5) when (execute_msr_setvalue_ena = '1') else
                          -- ldm^ with pc (exception return): T comes from the SPSR,
                          -- not from bit 0 of the loaded pc (which is a plain
                          -- stacked return address, bit 0 clear even for thumb).
                          -- Must hold through DATARW_BLOCKSWITCH: the target fetch
                          -- issues on that cycle, one cycle before thumbmode
                          -- updates, and drives the fetch step (+2/+4) and size
                          SPSR(5)                 when (decode_functions_detail = block_read and decode_block_switchmode = '1' and
                                                        ((execute_writeback = '1' and execute_writereg = x"F") or
                                                         execute_RW_State = DATARW_READWAIT or
                                                         execute_RW_State = DATARW_READWAITDMA or
                                                         execute_RW_State = DATARW_BLOCKSWITCH)) else
                          -- v5: loads to PC interwork from bit 0
                          execute_writedata(0)    when (execute_writeback = '1' and execute_writereg = x"F" and
                                                        (decode_functions_detail = data_read or decode_functions_detail = block_read)) else
                          '1'                     when (decode_branch_forcethumb = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          '0'                     when (decode_branch_forcearm   = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          execute_op2(0)          when (decode_set_thumbmode = '1' and execute_branch = '1' and decode_functions_detail = branch_all) else
                          thumbmode;

   -- exception vectors sit at 0xFFFF0000 when CP15 control bit 13 is set
   exception_base <= x"FFFF0000" when (cp15_control(13) = '1') else x"00000000";

   -- The `execute_writedata(31 downto 1) & '0' when (writeback and writereg=F)`
   -- term that used to sit third here is gone: it is the one late input in this
   -- mux and it is now handled at the far end, in the gb_bus_Adr / bus_AddrFetch_eff
   -- pair above. Everything left is register-derived. Leaving a redundant copy
   -- here would have bought nothing - static timing does not know the two
   -- conditions are mutually exclusive, so the long path would still be reported
   -- (and still be routed).
   execute_branchPC <= exception_base + 16#18#                                                  when (decode_functions_detail = IRQ) else
                       exception_base + 16#08#                                                  when (decode_functions_detail = software_interrupt_detail) else
                       (execute_op2(31 downto 1) & '0' + (decode_immidiate(10 downto 0) & '0')) when (decode_branch_long = '1') else
                       execute_op2(31 downto 1) & '0'                                           when (decode_branch_usereg = '1') else
                       unsigned(signed(decode_PC) + resize(decode_branch_immi, 32));
   
   execute_branchPC_masked(31 downto 2) <= execute_branchPC(31 downto 2);
   execute_branchPC_masked(1) <= execute_branchPC(1) when (execute_nextIsthumb = '1') else '0';
   execute_branchPC_masked(0) <= '0';
   
   
   -- register writeback
   process (all)
   begin
      
      execute_done      <= '0';
      
      execute_writeback <= '0';
      execute_writedata <= (others => '0');
      execute_writereg  <= unsigned(decode_rdest);
   
      if (execute_now) then
      
         if (execute_skip = '1') then
         
            execute_done <= '1';
         
         else

            case decode_functions_detail is
               
               when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
                  if (decode_alu_use_shift = '1' and decode_shift_regbased = '1') then
                     -- wait for shift
                  else
                     execute_writedata <= alu_result;
                     execute_writeback <= decode_writeback;
                     execute_done      <= '1';
                  end if;
            
               when data_processing_MRS =>
                  if (decode_psr_with_spsr = '1') then
                     execute_writedata <= SPSR;
                  else
                     execute_writedata <= CPSR;
                  end if;
                  execute_writeback <= '1';
                  execute_done      <= '1';
                  
               when data_processing_MSR =>
                  execute_done <= '1';
            
               when branch_all =>
                  execute_done <= '1';

               when alu_clz =>
                  execute_writedata <= execute_clz_result;
                  execute_writeback <= '1';
                  execute_done      <= '1';

               when sat_arith =>
                  execute_writedata <= execute_sat_result;
                  execute_writeback <= '1';
                  execute_done      <= '1';

               when cp15_op =>
                  if (execute_cp15_cacheop = '1') then
                     -- MCR c7 cache maintenance: done arrives when nds_cache9
                     -- has finished (stall section below)
                  else
                     execute_done <= '1';
                     if (decode_cp15_mrc = '1' and decode_rdest /= x"F") then
                        execute_writedata <= unsigned(cp15_rdata);
                        execute_writeback <= '1';
                     end if;
                  end if;

               when nop_detail =>
                  execute_done <= '1';

               when IRQ =>
                  execute_done      <= '1';
                  execute_writeback <= '1';
                  if (thumbmode = '1') then
                     execute_writedata <= decode_PC;
                  else
                     execute_writedata <= decode_PC - 4;
                  end if;
                  
               when software_interrupt_detail =>
                  execute_done      <= '1';     
                  execute_writeback <= '1';
                  if (thumbmode = '1') then
                     execute_writedata <= decode_PC - 2;
                  else
                     execute_writedata <= decode_PC - 4;
                  end if;
                  
               when others => null;
            
            end case;
            
         end if;
         
      end if;
      
      if (execute_stall = '1') then
       
         case decode_functions_detail is
          
            when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
               execute_done <= '1';
               execute_writedata <= alu_result;
               execute_writeback <= decode_writeback;
               execute_done      <= '1';
               
            when mulboth =>
               case (execute_MUL_State) is
                  when MUL_MUL =>
                     if (execute_mul_wait = 0) then
                        if (decode_mul_useadd = '0') then 
                           execute_writeback <= '1';
                           execute_writereg  <= unsigned(decode_RM_op2);
                           execute_writedata <= execute_mul_result(31 downto 0); 
                           if (decode_mul_long = '0') then
                              execute_done <= '1';
                              execute_writereg  <= unsigned(decode_rdest);
                           end if;
                        end if;
                     end if;
                     
                  when MUL_ADD =>
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_RM_op2);
                     execute_writedata <= execute_mul_result(31 downto 0); 
                     if (decode_mul_long = '0') then
                        execute_done <= '1';
                        execute_writereg  <= unsigned(decode_rdest);
                     end if;
                     
                  when MUL_STOREHI =>
                     execute_done <= '1';
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_rdest);
                     execute_writedata <= execute_mul_result(63 downto 32);

                  when others => null;
               end case;

            when cp15_op =>
               -- cache maintenance op completing
               if (execute_cacheop_wait = '1' and cache_op_ena = '0' and cache_op_busy = '0') then
                  execute_done <= '1';
               end if;

            when mul_dsp =>
               case (execute_MUL_State) is
                  when MUL_DSP_ACC =>
                     execute_writeback <= '1';
                     execute_writedata <= execute_dsp_sum;
                     if (decode_dsp_long = '1') then
                        execute_writereg <= unsigned(decode_Rn_op1); -- RdLo (swapped in)
                     else
                        execute_writereg <= unsigned(decode_rdest);
                        execute_done     <= '1';
                     end if;

                  when MUL_DSP_ACCHI =>
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_rdest);   -- RdHi
                     if (execute_dsp_carry = '1') then
                        execute_writedata <= execute_mul_result(63 downto 32) + execute_op1 + 1;
                     else
                        execute_writedata <= execute_mul_result(63 downto 32) + execute_op1;
                     end if;
                     execute_done <= '1';

                  when others => null;
               end case;
          
            when data_read | data_write =>
               if (execute_RW_State = DATARW_READWAITDMA) then
                  if (dma_on = '0') then
                     execute_done <= '1';
                  end if;
               end if;
               
               if (execute_RW_State = DATARW_READWAIT) then
                  if (dma_on_1 = '0' or dma_on = '0') then
                     execute_done      <= '1';
                  end if;
               end if;
            
               if (execute_RW_State = DATARW_READWAIT or execute_RW_State = DATARW_SWAPWRITE) then
                  execute_writeback <= '1';
                  case (decode_datareceivetype) is
                     when RECEIVETYPE_BYTE       => execute_writedata <= x"000000" & unsigned(execute_RW_dataRead(7 downto 0));
                     when RECEIVETYPE_WORD       => execute_writedata <= unsigned(execute_RW_dataRead); -- !!!
                     when RECEIVETYPE_DWORD      => execute_writedata <= unsigned(execute_RW_dataRead);
                     when RECEIVETYPE_SIGNEDBYTE => execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(7 downto 0)), 32));
                     when RECEIVETYPE_SIGNEDWORD =>
                        if (execute_RW_addr_last(0) = '0') then
                           execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(15 downto 0)), 32));
                        else
                           execute_writedata <= unsigned(resize(signed(execute_RW_dataRead(7 downto 0)), 32));
                        end if;
                  end case;
                  if (decode_datatransfer_double = '1') then
                     execute_writereg <= unsigned(decode_rdest) + 1; -- LDRD second word
                  end if;
               end if;

               -- LDRD first word writes back the moment its beat completes
               if (decode_datatransfer_double = '1' and execute_RW_State = DATARW_READSTART and
                   busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                  execute_writeback <= '1';
                  execute_writereg  <= unsigned(decode_rdest);
                  execute_writedata <= unsigned(gb_bus_din);
               end if;

               if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                  if (decode_functions_detail = data_write and
                      (decode_datatransfer_double = '0' or execute_RW_State = DATARW_WRITE_D2)) then
                     execute_done      <= '1';
                  end if;
                  -- for doubles the base writeback waits for the second beat so
                  -- it cannot collide with the first data writeback
                  if (decode_datatransfer_writeback = '1' and
                      (decode_datatransfer_double = '0' or
                       execute_RW_State = DATARW_READSTART_D2 or execute_RW_State = DATARW_WRITE_D2)) then
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_Rn_op1);
                     execute_writedata <= execute_RW_WBaddr;
                  end if;
               end if;

               if (execute_RW_State = DATARW_SWAPWAIT) then
                  execute_done      <= '1';
               end if;               

            when block_read | block_write =>
               if (execute_RW_State = DATARW_READWAITDMA) then
                  if (dma_on = '0' and decode_block_switchmode = '0') then
                     execute_done <= '1';
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT or (decode_functions_detail = block_write and busState = BUSSTATE_WAITDATA and gb_bus_done = '1' and execute_blockRW_last = '1')) then
                  if (decode_datatransfer_writeback = '1') then
                     execute_writeback <= '1';
                     execute_writereg  <= unsigned(decode_Rn_op1);
                     execute_writedata <= execute_blockRW_endaddr;
                  end if;
               end if;

               if (execute_RW_State = DATARW_READWAIT) then
                  if ((dma_on_1 = '0' or dma_on = '0') and decode_block_switchmode = '0') then
                     execute_done      <= '1';
                  end if;
               end if;

               -- ldm^ with pc: retire on the switch cycle, after the base
               -- writeback landed in the old mode's register
               if (execute_RW_State = DATARW_BLOCKSWITCH) then
                  execute_done <= '1';
               end if;
               
               if (decode_functions_detail = block_read) then
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                     -- writes the LIVE regs(); complement of the user-bank
                     -- redirect, so r8-r12 land here in every mode but FIQ
                     if (decode_block_usermoderegs = '0' or cpu_mode = CPUMODE_USER or cpu_mode = CPUMODE_SYSTEM or
                         execute_blockRW_writereg < 8 or execute_blockRW_writereg > 14 or
                         (execute_blockRW_writereg <= 12 and cpu_mode /= CPUMODE_FIQ)) then
                        execute_writeback <= '1';
                     end if;
                     execute_writereg  <= execute_blockRW_writereg;
                     execute_writedata <= unsigned(gb_bus_din);  
                  end if;
               else
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1' and execute_blockRW_last = '1') then
                     execute_done      <= '1';
                  end if;
               end if;
               
             when others => null;
               
         end case;
       
      end if;

   end process;
   
   process (clk)
      variable dsp_ra    : signed(15 downto 0);
      variable dsp_rb    : signed(15 downto 0);
      variable dsp_p     : signed(31 downto 0);
      variable dsp_pw    : signed(47 downto 0);
      variable dsp_sum33 : unsigned(32 downto 0);
      variable cp15_wval : std_logic_vector(31 downto 0);
      variable v_cacheop : std_logic_vector(3 downto 0);
   begin
      if (rising_edge(clk)) then

         done <= execute_done;

         error_cpu <= '0';

         if (reset = '1') then

            execute_stall    <= '0';
            Flag_Q_Sticky     <= '0';
            execute_dsp_carry <= '0';
            -- Post-BIOS CP15 state. HLE direct boot jumps straight to the
            -- cart's ARM9 entry, so the ARM9 BIOS never runs and never
            -- programs any of this - but NitroSDK's very 4th instruction is
            -- `mrc p15,0,r0,c1,c0,0` followed by a read-modify-write, so
            -- whatever is missing here stays missing for the whole boot.
            -- Values are melonDS's SetupDirectBoot (src/NDS.cpp), which is the
            -- oracle these were differentially matched against; 0x78 alone
            -- loses bit 13 (V, high exception vectors) and bit 16 (DTCM enable).
            cp15_control      <= x"00012078";   -- c1,c0,0
            cp15_dtcm_reg     <= x"0300000A";   -- c9,c1,0  base 0x03000000, 16 KB
            cp15_itcm_reg     <= x"00000020";   -- c9,c1,1  32 KB at 0
            cp15_pu_region(0) <= x"04000033";   -- c6,c0
            cp15_pu_region(1) <= x"0200002B";   -- c6,c1
            cp15_pu_region(2) <= x"00000000";   -- c6,c2
            cp15_pu_region(3) <= x"08000035";   -- c6,c3
            cp15_pu_region(4) <= x"0300001B";   -- c6,c4
            cp15_pu_region(5) <= x"00000000";   -- c6,c5
            cp15_pu_region(6) <= x"FFFF001D";   -- c6,c6
            cp15_pu_region(7) <= x"027FF017";   -- c6,c7
            cp15_pu_dcache    <= x"00000042";   -- c2,c0,0
            cp15_pu_icache    <= x"00000042";   -- c2,c0,1
            cp15_pu_wbuf      <= x"00000002";   -- c3,c0,0
            cp15_pu_dperm     <= x"15111011";   -- c5,c0,2
            cp15_pu_iperm     <= x"05100011";   -- c5,c0,3
            cp15_dcache_lock  <= (others => '0');
            cp15_icache_lock  <= (others => '0');
            cp15_trace_pid    <= (others => '0');
            
            Flag_Zero       <= SAVESTATE_Flag_Zero;      
            Flag_Carry      <= SAVESTATE_Flag_Carry;     
            Flag_Negative   <= SAVESTATE_Flag_Negative;  
            Flag_V_Overflow <= SAVESTATE_Flag_V_Overflow;
            thumbmode       <= SAVESTATE_thumbmode;      
            cpu_mode        <= SAVESTATE_cpu_mode;       
            IRQ_disable     <= SAVESTATE_IRQ_disable;    
            FIQ_disable     <= SAVESTATE_FIQ_disable;    
            
            for i in 0 to 15 loop 
               regs(i) <= unsigned(SAVESTATE_REGS(i));
            end loop;
            
            regs_0_8  <= unsigned(SAVESTATE_REGS_0_8 );
            regs_0_9  <= unsigned(SAVESTATE_REGS_0_9 );
            regs_0_10 <= unsigned(SAVESTATE_REGS_0_10);
            regs_0_11 <= unsigned(SAVESTATE_REGS_0_11);
            regs_0_12 <= unsigned(SAVESTATE_REGS_0_12);
            regs_0_13 <= unsigned(SAVESTATE_REGS_0_13);
            regs_0_14 <= unsigned(SAVESTATE_REGS_0_14);
            regs_1_8  <= unsigned(SAVESTATE_REGS_1_8 );
            regs_1_9  <= unsigned(SAVESTATE_REGS_1_9 );
            regs_1_10 <= unsigned(SAVESTATE_REGS_1_10);
            regs_1_11 <= unsigned(SAVESTATE_REGS_1_11);
            regs_1_12 <= unsigned(SAVESTATE_REGS_1_12);
            regs_1_13 <= unsigned(SAVESTATE_REGS_1_13);
            regs_1_14 <= unsigned(SAVESTATE_REGS_1_14);
            regs_1_17 <= unsigned(SAVESTATE_REGS_1_17);
            regs_2_13 <= unsigned(SAVESTATE_REGS_2_13);
            regs_2_14 <= unsigned(SAVESTATE_REGS_2_14);
            regs_2_17 <= unsigned(SAVESTATE_REGS_2_17);
            regs_3_13 <= unsigned(SAVESTATE_REGS_3_13);
            regs_3_14 <= unsigned(SAVESTATE_REGS_3_14);
            regs_3_17 <= unsigned(SAVESTATE_REGS_3_17);
            regs_4_13 <= unsigned(SAVESTATE_REGS_4_13);
            regs_4_14 <= unsigned(SAVESTATE_REGS_4_14);
            regs_4_17 <= unsigned(SAVESTATE_REGS_4_17);
            regs_5_13 <= unsigned(SAVESTATE_REGS_5_13);
            regs_5_14 <= unsigned(SAVESTATE_REGS_5_14);
            regs_5_17 <= unsigned(SAVESTATE_REGS_5_17);
            
            execute_RW_State  <= DATARW_IDLE;
            execute_MUL_State <= MUL_IDLE;
            alu_wait_shift   <= '0';
            cache_op_ena         <= '0';
            execute_cacheop_wait <= '0';

         elsif (ce = '1') then

            cache_op_ena <= '0';
            
            if (execute_writeback = '1' and execute_writereg /= 15) then
               regs(to_integer(execute_writereg)) <= execute_writedata;
            end if;

            -- v5: a load that writes PC interworks from bit 0 (but ldm^ with
            -- pc takes T from the SPSR restore, not from the loaded value)
            if (execute_writeback = '1' and execute_writereg = 15 and
                (decode_functions_detail = data_read or
                 (decode_functions_detail = block_read and decode_block_switchmode = '0'))) then
               thumbmode <= execute_writedata(0);
            end if;

            if (execute_done = '1') then
               Flag_Carry      <= execute_flag_Carry;
               Flag_Zero       <= execute_flag_Zero;
               Flag_Negative   <= execute_flag_Negative;
               Flag_V_Overflow <= execute_flag_V_Overflow;
            end if;

            if (execute_msr_setvalue_ena = '1') then
               cpu_mode           <= execute_switchmode_new;
               thumbmode          <= execute_msr_setvalue(5);
               FIQ_disable        <= execute_msr_setvalue(6);
               IRQ_disable        <= execute_msr_setvalue(7);
               Flag_Negative      <= execute_msr_setvalue(31);
               Flag_Zero          <= execute_msr_setvalue(30);
               Flag_Carry         <= execute_msr_setvalue(29);
               Flag_V_Overflow    <= execute_msr_setvalue(28);
               Flag_Q_Sticky      <= execute_msr_setvalue(27);
            end if;
            
            if (execute_stall = '1') then

               if (alu_wait_shift = '1') then
                  execute_stall  <= '0';
                  alu_wait_shift <= '0';
               end if;

               -- cache maintenance: wait for nds_cache9 to finish (busy is
               -- combinationally high from the ena pulse onwards)
               if (execute_cacheop_wait = '1' and cache_op_ena = '0' and cache_op_busy = '0') then
                  execute_cacheop_wait <= '0';
                  execute_stall        <= '0';
               end if;
               
               if (decode_functions_detail = mulboth) then
                  case (execute_MUL_State) is
                     when MUL_MUL =>
                        if (execute_mul_wait > 0) then
                           execute_mul_wait <= execute_mul_wait - 1;
                        else
                           if (decode_mul_useadd = '1') then 
                              execute_MUL_State  <= MUL_ADD;
                              if (decode_mul_long = '1') then
                                 execute_mul_result <= execute_mul_result + (execute_op1 & execute_op2);
                              else
                                 execute_mul_result <= execute_mul_result + execute_op2;
                              end if;
                           elsif (decode_mul_long = '1') then
                              execute_MUL_State <= MUL_STOREHI;
                           else
                              execute_MUL_State <= MUL_IDLE;
                              execute_stall     <= '0';
                           end if;
                        end if;
                        
                     when MUL_ADD =>
                        if (decode_mul_long = '1') then
                           execute_MUL_State <= MUL_STOREHI;
                        else
                           execute_MUL_State <= MUL_IDLE;
                           execute_stall     <= '0';
                        end if;
                        
                     when MUL_STOREHI =>
                        execute_MUL_State <= MUL_IDLE;
                        execute_stall     <= '0';

                     when others => null;
                  end case;
               end if;

               if (decode_functions_detail = mul_dsp) then
                  case (execute_MUL_State) is
                     when MUL_DSP_ACC =>
                        if (decode_dsp_long = '1') then
                           dsp_sum33 := ('0' & execute_mul_result(31 downto 0)) + ('0' & execute_op1);
                           execute_dsp_carry <= dsp_sum33(32);
                           execute_MUL_State <= MUL_DSP_ACCHI;
                        else
                           if (execute_dsp_qset = '1') then
                              Flag_Q_Sticky <= '1';
                           end if;
                           execute_MUL_State <= MUL_IDLE;
                           execute_stall     <= '0';
                        end if;

                     when MUL_DSP_ACCHI =>
                        execute_MUL_State <= MUL_IDLE;
                        execute_stall     <= '0';

                     when others => null;
                  end case;
               end if;
               
               if (decode_functions_detail = block_read) then
                  if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                     if (decode_block_usermoderegs = '1' and cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM and
                         ((execute_blockRW_writereg >= 13 and execute_blockRW_writereg <= 14) or
                          (execute_blockRW_writereg >= 8  and execute_blockRW_writereg <= 12 and cpu_mode = CPUMODE_FIQ))) then
                        case (to_integer(unsigned(execute_blockRW_writereg))) is
                           when 8  => regs_0_8  <= unsigned(gb_bus_din);
                           when 9  => regs_0_9  <= unsigned(gb_bus_din);
                           when 10 => regs_0_10 <= unsigned(gb_bus_din);
                           when 11 => regs_0_11 <= unsigned(gb_bus_din);
                           when 12 => regs_0_12 <= unsigned(gb_bus_din);
                           when 13 => regs_0_13 <= unsigned(gb_bus_din);
                           when 14 => regs_0_14 <= unsigned(gb_bus_din);
                           when others => null;
                        end case;
                     end if;
                  end if;
               end if;
         
               case (execute_RW_State) is
                  when DATARW_READSTART =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_dataRead <= gb_bus_din;
                        if (decode_datatransfer_swap = '1') then
                           execute_RW_State <= DATARW_SWAPWRITE;
                        elsif (decode_datatransfer_double = '1') then
                           execute_RW_State <= DATARW_READSTART_D2;
                        else
                           execute_RW_State <= DATARW_READWAIT;
                        end if;
                     end if;

                  when DATARW_READSTART_D2 =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_dataRead <= gb_bus_din;
                        execute_RW_State    <= DATARW_READWAIT;
                     end if;
                     
                  when DATARW_READWAIT =>
                     if (dma_on_1 = '0' or dma_on = '0') then
                        if (decode_functions_detail = block_read and decode_block_switchmode = '1') then
                           execute_RW_State <= DATARW_BLOCKSWITCH;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall    <= '0';
                        end if;
                     else
                        execute_RW_State <= DATARW_READWAITDMA;
                     end if;

                  when DATARW_READWAITDMA =>
                     if (dma_on = '0') then
                        if (decode_functions_detail = block_read and decode_block_switchmode = '1') then
                           execute_RW_State <= DATARW_BLOCKSWITCH;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall    <= '0';
                        end if;
                     end if;
                     
                  when DATARW_WRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        if (decode_datatransfer_double = '1') then
                           execute_RW_State <= DATARW_WRITE_D2;
                        else
                           execute_RW_State <= DATARW_IDLE;
                           execute_stall    <= '0';
                        end if;
                     end if;

                  when DATARW_WRITE_D2 =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_State <= DATARW_IDLE;
                        execute_stall    <= '0';
                     end if;
                     
                  when DATARW_SWAPWRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_RW_State <= DATARW_SWAPWAIT;
                     end if;
                     
                  when DATARW_SWAPWAIT =>
                     execute_RW_State <= DATARW_IDLE;
                     execute_stall    <= '0';  
                     
                  when DATARW_BLOCKREAD =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        if (execute_blockRW_last = '1') then
                           execute_RW_State <= DATARW_READWAIT;
                        else
                           execute_blockRW_addr <= execute_RW_addr + 4;
                        end if;
                        if (execute_RW_ena = '1') then
                           execute_blockRW_writereg <= unsigned(decode_RM_op2);
                        end if;
                     end if;
                  
                  when DATARW_BLOCKWRITE =>
                     if (busState = BUSSTATE_WAITDATA and gb_bus_done = '1') then
                        execute_blockRW_addr <= execute_RW_addr + 4;
                        if (execute_blockRW_last = '1') then
                           execute_RW_State   <= DATARW_IDLE;
                           execute_stall        <= '0';
                        end if;
                     end if;

                  when DATARW_BLOCKSWITCH =>
                     execute_RW_State <= DATARW_IDLE;
                     execute_stall    <= '0';

                  when others => null;
               end case;
         
            elsif (execute_now = '1') then
            
               regs(15) <= decode_PC;
            
               -- synthesis translate_off
               execute_opcode_export <= decode_opcode_export;
               -- synthesis translate_on 
            
               if (execute_skip = '0') then
                  case decode_functions_detail is
                     
                     when branch_all =>
                        if (decode_branch_link = '1') then
                           if (decode_branch_long = '1') then
                              regs(14) <= decode_PC - 2;
                              regs(14)(0) <= '1';
                           else
                              regs(14) <= decode_PC - 4;
                           end if;
                        end if;
                        if (decode_set_thumbmode = '1') then
                           thumbmode <= execute_op2(0);
                        end if;
                        if (decode_branch_forcethumb = '1') then
                           thumbmode <= '1';   -- ARM BLX <label>
                        end if;
                        if (decode_branch_forcearm = '1') then
                           thumbmode <= '0';   -- Thumb BLX suffix
                        end if;
                     
                     when alu_and | alu_xor | alu_add | alu_sub | alu_add_withcarry | alu_sub_withcarry | alu_or | alu_mov | alu_and_not | alu_mov_not =>
                        if (decode_alu_use_shift = '1' and decode_shift_regbased = '1') then
                           execute_stall  <= '1';
                           alu_wait_shift <= '1';
                        end if;
                  
                     when data_processing_MRS => null;
                     
                     when data_processing_MSR =>
                        if (decode_psr_with_spsr = '1') then
                           case (cpu_mode) is
                              when CPUMODE_FIQ        => regs_1_17 <= execute_msr_writevalue;
                              when CPUMODE_IRQ        => regs_2_17 <= execute_msr_writevalue;
                              when CPUMODE_SUPERVISOR => regs_3_17 <= execute_msr_writevalue;
                              when CPUMODE_ABORT      => regs_4_17 <= execute_msr_writevalue;
                              when CPUMODE_UNDEFINED  => regs_5_17 <= execute_msr_writevalue;
                              when others => null;
                           end case;
                        end if;
                        
                     when mulboth =>
                        execute_stall        <= '1';
                        execute_MUL_State    <= MUL_MUL;

                        execute_mul_wait <= 3;
                        if    (execute_op2(31 downto 8)  = x"000000") then execute_mul_wait <= 0;
                        elsif (execute_op2(31 downto 16) = x"0000"  ) then execute_mul_wait <= 1;
                        elsif (execute_op2(31 downto 24) = x"00"    ) then execute_mul_wait <= 2; end if;  
                        if (decode_mul_long = '0' or decode_mul_signed = '1') then
                           if    (execute_op2(31 downto 8)  = x"FFFFFF") then execute_mul_wait <= 0;
                           elsif (execute_op2(31 downto 16) = x"FFFF"  ) then execute_mul_wait <= 1;
                           elsif (execute_op2(31 downto 24) = x"FF"    ) then execute_mul_wait <= 2; end if;
                        end if;                        

                        if (decode_mul_long = '0' or decode_mul_signed = '0') then
                           execute_mul_result <= execute_op1 * execute_op2;
                        else
                           execute_mul_result <= unsigned(signed(execute_op1) * signed(execute_op2));
                        end if;
                  
                     when data_read | data_write =>
                        execute_stall    <= '1';
                        if (decode_functions_detail = data_read) then
                           execute_RW_State <= DATARW_READSTART;
                        else
                           execute_RW_State <= DATARW_WRITE;
                        end if;

                        if (decode_datatransfer_addup = '1') then
                           execute_RW_WBaddr <= execute_busaddress + execute_busaddmod;
                        else
                           execute_RW_WBaddr <= execute_busaddress - execute_busaddmod;
                        end if;
                        if (decode_shift_regbased = '1') then
                           error_cpu <= '1';
                        end if;
                  
                     when block_read | block_write =>
                        if (decode_functions_detail = block_read) then
                           execute_RW_State         <= DATARW_BLOCKREAD;
                        else
                           execute_RW_State         <= DATARW_BLOCKWRITE;
                        end if;
                        execute_stall            <= '1';
                        execute_blockRW_writereg <= unsigned(decode_RM_op2);
                        execute_blockRW_endaddr  <= unsigned(signed(execute_busaddress) + decode_block_endmod);
                        -- First beat only, so execute_stall is still '0' and the
                        -- combinational execute_RW_addr above is the
                        -- `execute_busaddress + decode_block_addrmod` branch (the
                        -- later beats at DATARW_BLOCKREAD/BLOCKWRITE take the
                        -- registered execute_blockRW_addr branch and already cost
                        -- one adder). Writing `execute_RW_addr + 4` here chained a
                        -- second 32-bit adder onto that one; folding the constant
                        -- into decode_block_addrmod - a decode-stage integer -
                        -- leaves a single adder on execute_busaddress.
                        --
                        -- The low-bit clear commutes with the +4: masking then
                        -- adding 4 and adding 4 then masking both give
                        -- X - (X mod 4) + 4, so applying it after is identical to
                        -- execute_RW_addr(1 downto 0) <= "00" happening before.
                        execute_blockRW_addr     <= unsigned(signed(execute_busaddress) + (decode_block_addrmod + 4));
                        execute_blockRW_addr(1 downto 0) <= "00";
                  
                     when IRQ =>
                        IRQ_disable <= '1';
                        thumbmode   <= '0';
                        done        <= '0';
                        cpu_mode    <= CPUMODE_IRQ;

                     when software_interrupt_detail =>
                        IRQ_disable <= '1';
                        thumbmode   <= '0';
                        cpu_mode    <= CPUMODE_SUPERVISOR;

                     -- ================= v5TE =================

                     when alu_clz | nop_detail => null;

                     when sat_arith =>
                        if (execute_sat_qset = '1') then
                           Flag_Q_Sticky <= '1';
                        end if;

                     when mul_dsp =>
                        execute_stall     <= '1';
                        execute_MUL_State <= MUL_DSP_ACC;
                        if (decode_dsp_x = '1') then
                           dsp_ra := signed(execute_op2(31 downto 16)); -- Rm half
                        else
                           dsp_ra := signed(execute_op2(15 downto 0));
                        end if;
                        if (decode_dsp_y = '1') then
                           dsp_rb := signed(execute_op1(31 downto 16)); -- Rs half
                        else
                           dsp_rb := signed(execute_op1(15 downto 0));
                        end if;
                        if (decode_dsp_word = '1') then
                           dsp_pw := signed(execute_op2) * dsp_rb;      -- SMULWy/SMLAWy
                           execute_mul_result <= unsigned(resize(dsp_pw(47 downto 16), 64));
                        else
                           dsp_p := dsp_ra * dsp_rb;                    -- 16x16
                           execute_mul_result <= unsigned(resize(dsp_p, 64));
                        end if;

                     when cp15_op =>
                        if (decode_cp15_mrc = '1') then
                           if (decode_rdest = x"F") then
                              Flag_Negative   <= cp15_rdata(31);
                              Flag_Zero       <= cp15_rdata(30);
                              Flag_Carry      <= cp15_rdata(29);
                              Flag_V_Overflow <= cp15_rdata(28);
                           end if;
                        else
                           cp15_wval := std_logic_vector(execute_opDest);
                           case (decode_cp15_crn) is
                              when x"1" =>
                                 cp15_control <= (cp15_wval and x"000FF085") or x"00000078";
                              when x"2" =>
                                 if (decode_cp15_op2(0) = '1') then
                                    cp15_pu_icache <= cp15_wval;
                                 else
                                    cp15_pu_dcache <= cp15_wval;
                                 end if;
                              when x"3" => cp15_pu_wbuf <= cp15_wval;
                              when x"5" =>
                                 if (decode_cp15_op2(0) = '1') then
                                    cp15_pu_iperm <= cp15_wval;
                                 else
                                    cp15_pu_dperm <= cp15_wval;
                                 end if;
                              when x"6" =>
                                 cp15_pu_region(to_integer(unsigned(decode_cp15_crm(2 downto 0)))) <= cp15_wval;
                              when x"7" =>
                                 -- cache maintenance -> nds_cache9 (wfi c7,c0,4
                                 -- is handled in decode; c7,c10,4 drain write
                                 -- buffer and c7,c13,1 prefetch are no-ops)
                                 v_cacheop := "1111"; -- invalid = no op
                                 case (decode_cp15_crm) is
                                    when x"5" =>
                                       if    (decode_cp15_op2 = "000") then v_cacheop := "0000";
                                       elsif (decode_cp15_op2 = "001") then v_cacheop := "0001";
                                       end if;
                                    when x"6" =>
                                       if    (decode_cp15_op2 = "000") then v_cacheop := "0010";
                                       elsif (decode_cp15_op2 = "001") then v_cacheop := "0011";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "0100";
                                       end if;
                                    when x"A" =>
                                       if    (decode_cp15_op2 = "001") then v_cacheop := "0101";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "0110";
                                       end if;
                                    when x"E" =>
                                       if    (decode_cp15_op2 = "001") then v_cacheop := "0111";
                                       elsif (decode_cp15_op2 = "010") then v_cacheop := "1000";
                                       end if;
                                    when others => null;
                                 end case;
                                 if (v_cacheop /= "1111") then
                                    cache_op             <= v_cacheop;
                                    cache_op_addr        <= cp15_wval;
                                    cache_op_ena         <= '1';
                                    execute_stall        <= '1';
                                    execute_cacheop_wait <= '1';
                                 end if;
                              when x"9" =>
                                 if (decode_cp15_crm = x"1") then
                                    if (decode_cp15_op2 = "001") then
                                       cp15_itcm_reg <= cp15_wval;
                                    else
                                       cp15_dtcm_reg <= cp15_wval;
                                    end if;
                                 else
                                    if (decode_cp15_op2 = "001") then
                                       cp15_icache_lock <= cp15_wval;
                                    else
                                       cp15_dcache_lock <= cp15_wval;
                                    end if;
                                 end if;
                              when x"D" => cp15_trace_pid <= cp15_wval;
                              when others => null;
                           end case;
                        end if;

                     when others =>
                        error_cpu <= '1';
                        report "not implemented execute function" severity failure;

                  end case;

               end if;


            end if;

            -- mode switch + bank swap: at execute_now for the single-cycle
            -- switch sources (msr, exception entry, subs pc), and in the
            -- DATARW_BLOCKSWITCH cycle for ldm^ with pc (the swap must land
            -- AFTER the base writeback wrote the old mode's register)
            if (execute_switchmode_now = '1' and
                (execute_now = '1' or execute_RW_State = DATARW_BLOCKSWITCH)) then

                  if (execute_switchmode_new = CPUMODE_FIQ and cpu_mode /= CPUMODE_FIQ) then
                     regs_0_8  <= regs(8);
                     regs_0_9  <= regs(9);
                     regs_0_10 <= regs(10);
                     regs_0_11 <= regs(11);
                     regs_0_12 <= regs(12);
                  end if;
                  
                  case (cpu_mode) is
                     when CPUMODE_USER | CPUMODE_SYSTEM =>
                        regs_0_13 <= regs(13);
                        regs_0_14 <= regs(14);
      
                     when CPUMODE_FIQ =>
                        regs_1_8  <= regs(8);
                        regs_1_9  <= regs(9);
                        regs_1_10 <= regs(10);
                        regs_1_11 <= regs(11);
                        regs_1_12 <= regs(12);
                        regs_1_13 <= regs(13);
                        regs_1_14 <= regs(14);
      
                     when CPUMODE_IRQ =>
                        regs_2_13 <= regs(13);
                        regs_2_14 <= regs(14);
      
                     when CPUMODE_SUPERVISOR =>
                        regs_3_13 <= regs(13);
                        regs_3_14 <= regs(14);
      
                     when CPUMODE_ABORT =>
                        regs_4_13 <= regs(13);
                        regs_4_14 <= regs(14);
      
                     when CPUMODE_UNDEFINED =>
                        regs_5_13 <= regs(13);
                        regs_5_14 <= regs(14);
                           
                     when others => report "should never happen" severity failure; 
                  end case;

                  case (execute_switchmode_new) is
                     when CPUMODE_USER | CPUMODE_SYSTEM =>
                        if (cpu_mode /= CPUMODE_USER and cpu_mode /= CPUMODE_SYSTEM) then
                           regs(13) <= regs_0_13;
                           regs(14) <= regs_0_14;
                        end if;
      
                     when CPUMODE_FIQ =>
                        if (cpu_mode /= CPUMODE_FIQ) then
                           regs(8)  <= regs_1_8 ;
                           regs(9)  <= regs_1_9 ;
                           regs(10) <= regs_1_10;
                           regs(11) <= regs_1_11;
                           regs(12) <= regs_1_12;
                           regs(13) <= regs_1_13;
                           regs(14) <= regs_1_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_1_17 <= CPSR; end if;
      
                     when CPUMODE_IRQ =>
                        if (cpu_mode /= CPUMODE_IRQ) then
                           regs(13) <= regs_2_13;
                           if (decode_functions_detail /= IRQ) then
                              regs(14) <= regs_2_14;
                           end if;
                        end if;
                        if (execute_switchmode_state = '1') then regs_2_17 <= CPSR; end if;
      
                     when CPUMODE_SUPERVISOR =>
                        if (cpu_mode /= CPUMODE_SUPERVISOR) then
                           regs(13) <= regs_3_13;
                           if (decode_functions_detail /= software_interrupt_detail) then
                              regs(14) <= regs_3_14;
                           end if;
                        end if;
                        if (execute_switchmode_state = '1') then regs_3_17 <= CPSR; end if;
      
                     when CPUMODE_ABORT =>
                        if (cpu_mode /= CPUMODE_ABORT) then
                           regs(13) <= regs_4_13;
                           regs(14) <= regs_4_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_4_17 <= CPSR; end if;
      
                     when CPUMODE_UNDEFINED =>
                        if (cpu_mode /= CPUMODE_UNDEFINED) then
                           regs(13) <= regs_5_13;
                           regs(14) <= regs_5_14;
                        end if;
                        if (execute_switchmode_state = '1') then regs_5_17 <= CPSR; end if;
                           
                     when others => report "should never happen" severity failure; 
                  end case;
                     
                  if (cpu_mode = CPUMODE_FIQ and execute_switchmode_new /= CPUMODE_FIQ) then
                     regs(8)  <= regs_0_8;
                     regs(9)  <= regs_0_9;
                     regs(10) <= regs_0_10;
                     regs(11) <= regs_0_11;
                     regs(12) <= regs_0_12;
                  end if;

            end if;
         
         end if;
         
      end if;
   end process;
   
   
   -- synthesis translate_off
   goutput : if is_simu = '1' generate
      signal export_halt     : std_logic := '0';
      signal decode_unhalt_1 : std_logic := '0';
   begin
   
      process
      begin
      
         while (true) loop
            wait until rising_edge(clk);
            
            cpu_export_done <= '0';
            
            if (execute_done = '1') then
               export_halt <= decode_halt;
            elsif (IRQ_in = '1') then
               export_halt <= '0';
            end if;
            
            decode_unhalt_1 <= decode_unhalt;
            
            if (((done = '1' or (export_halt = '1' and dma_on_1 = '0')) and decode_unhalt = '0') or decode_unhalt_1 = '1') then
               
               while (decode_ready = '0' and export_halt = '0' and reset = '0') loop
                  wait until rising_edge(clk);
               end loop;
               
               cpu_export_done <= not reset;
               for i in 0 to 14 loop
                  cpu_export.regs(i) <= regs(i);
               end loop;
               cpu_export.pc     <= regs(15);
               cpu_export.opcode <= unsigned(execute_opcode_export);
               cpu_export.CPSR   <= CPSR;
               cpu_export.SPSR   <= SPSR;
               cpu_export.regs_0_8  <= regs_0_8 ;
               cpu_export.regs_0_9  <= regs_0_9 ;
               cpu_export.regs_0_10 <= regs_0_10;
               cpu_export.regs_0_11 <= regs_0_11;
               cpu_export.regs_0_12 <= regs_0_12;
               cpu_export.regs_0_13 <= regs_0_13;
               cpu_export.regs_0_14 <= regs_0_14;
               cpu_export.regs_1_8  <= regs_1_8 ;
               cpu_export.regs_1_9  <= regs_1_9 ;
               cpu_export.regs_1_10 <= regs_1_10;
               cpu_export.regs_1_11 <= regs_1_11;
               cpu_export.regs_1_12 <= regs_1_12;
               cpu_export.regs_1_13 <= regs_1_13;
               cpu_export.regs_1_14 <= regs_1_14;
               cpu_export.regs_1_17 <= regs_1_17;
               cpu_export.regs_2_13 <= regs_2_13;
               cpu_export.regs_2_14 <= regs_2_14;
               cpu_export.regs_2_17 <= regs_2_17;
               cpu_export.regs_3_13 <= regs_3_13;
               cpu_export.regs_3_14 <= regs_3_14;
               cpu_export.regs_3_17 <= regs_3_17;
               cpu_export.regs_4_13 <= regs_4_13;
               cpu_export.regs_4_14 <= regs_4_14;
               cpu_export.regs_4_17 <= regs_4_17;
               cpu_export.regs_5_13 <= regs_5_13;
               cpu_export.regs_5_14 <= regs_5_14;
               cpu_export.regs_5_17 <= regs_5_17;
                  
            end if;
            
         end loop;
         
      end process;
      
   end generate goutput;
-- synthesis translate_on
   
   
   
end architecture;

