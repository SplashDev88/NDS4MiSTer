-- SPDX-License-Identifier: GPL-3.0-or-later
-- Standalone mapping estimate only. No MiSTer top-level integration or fit.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity checkpoint_area_probe is
  generic(ARM9:boolean:=true; CHECKPOINTS:boolean:=false; HALT_PIPELINE:boolean:=false);
  port(clk,reset,ce,dma,irq,unhalt,new_halt:in std_logic;
       ss_addr:in std_logic_vector(27 downto 0);
       ss_data:in std_logic_vector(31 downto 0);
       ss_rnw,ss_ena,ss_rst:in std_logic;
       ss_be:in std_logic_vector(3 downto 0);
       state_data:out std_logic_vector(31 downto 0);state_done:out std_logic;
       req,restore:in std_logic;paused:out std_logic;
       mem_addr,mem_data,last_read:out std_logic_vector(31 downto 0);
       mem_read,mem_ena,mem_seq,mem_code,mem_lock:out std_logic;
       mem_acc,mem_low:out std_logic_vector(1 downto 0);
       mem_input:in std_logic_vector(31 downto 0);mem_done:in std_logic;
       cpu_done,cpu_idle,in_bios,halt,jump,error:out std_logic;
       regsel:in unsigned(4 downto 0);regval:out std_logic_vector(31 downto 0);
       cp15_bits:out std_logic_vector(10 downto 0);
       tcm_base:out std_logic_vector(31 downto 12);
       tcm_size,itcm_size:out std_logic_vector(4 downto 0);
       cache_ena:out std_logic;cache_op:out std_logic_vector(3 downto 0);
       cache_addr:out std_logic_vector(31 downto 0);cache_busy:in std_logic);
end;
architecture rtl of checkpoint_area_probe is
  signal ss:proc_bus_gb_type;
  function preset_only return std_logic is
  begin if CHECKPOINTS then return '0';else return '1';end if;end;
begin
  ss <= (ss_data,ss_addr,ss_rnw,ss_ena,"10",ss_be,ss_rst);
  g9:if ARM9 generate
    cpu:entity work.nds_cpu9
      generic map(is_simu=>'0',SS_PRESET_ONLY=>preset_only,EXPERIMENTAL_CHECKPOINT=>CHECKPOINTS,
        EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
      port map(clk=>clk,ce=>ce,reset=>reset,savestate_bus=>ss,
        ss_wired_out=>state_data,ss_wired_done=>state_done,
        gb_bus_Adr=>mem_addr,gb_bus_dout=>mem_data,gb_bus_din=>mem_input,
        gb_bus_done=>mem_done,gb_bus_rnw=>mem_read,gb_bus_ena=>mem_ena,
        gb_bus_seq=>mem_seq,gb_bus_code=>mem_code,gb_bus_lock=>mem_lock,
        gb_bus_acc=>mem_acc,bus_lowbits=>mem_low,dma_on=>dma,done=>cpu_done,
        CPU_bus_idle=>cpu_idle,PC_in_BIOS=>in_bios,cpu_halt=>halt,lastread=>last_read,
        jump_out=>jump,error_cpu=>error,dbg_regsel=>regsel,dbg_regval=>regval,
        IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt,
        cp15_vector_hi=>cp15_bits(0),cp15_pu_enable=>cp15_bits(1),
        cp15_icache_ena=>cp15_bits(2),cp15_dcache_ena=>cp15_bits(3),
        cp15_itcm_ena=>cp15_bits(4),cp15_itcm_load=>cp15_bits(5),
        cp15_dtcm_ena=>cp15_bits(6),cp15_dtcm_load=>cp15_bits(7),
        bus_cacheable_i=>cp15_bits(8),bus_cacheable_d=>cp15_bits(9),
        bus_bufferable_d=>cp15_bits(10),cp15_dtcm_base=>tcm_base,
        cp15_dtcm_size=>tcm_size,cp15_itcm_size=>itcm_size,
        cache_op_ena=>cache_ena,cache_op=>cache_op,cache_op_addr=>cache_addr,
        cache_op_busy=>cache_busy,checkpoint_req=>req,checkpoint_paused=>paused,
        checkpoint_restore=>restore);
  end generate;
  g7:if not ARM9 generate
    cpu:entity work.gba_cpu
      generic map(is_simu=>'0',SS_PRESET_ONLY=>preset_only,EXPERIMENTAL_CHECKPOINT=>CHECKPOINTS,
        EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
      port map(clk=>clk,ce=>ce,reset=>reset,savestate_bus=>ss,
        ss_wired_out=>state_data,ss_wired_done=>state_done,
        gb_bus_Adr=>mem_addr,gb_bus_dout=>mem_data,gb_bus_din=>mem_input,
        gb_bus_done=>mem_done,gb_bus_rnw=>mem_read,gb_bus_ena=>mem_ena,
        gb_bus_seq=>mem_seq,gb_bus_code=>mem_code,gb_bus_lock=>mem_lock,
        gb_bus_acc=>mem_acc,bus_lowbits=>mem_low,dma_on=>dma,done=>cpu_done,
        CPU_bus_idle=>cpu_idle,PC_in_BIOS=>in_bios,cpu_halt=>halt,lastread=>last_read,
        jump_out=>jump,error_cpu=>error,dbg_regsel=>regsel,dbg_regval=>regval,
        IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt,
        checkpoint_req=>req,checkpoint_paused=>paused,checkpoint_restore=>restore);
    cp15_bits<=(others=>'0');tcm_base<=(others=>'0');tcm_size<=(others=>'0');
    itcm_size<=(others=>'0');cache_ena<='0';cache_op<=(others=>'0');cache_addr<=(others=>'0');
  end generate;
end;
