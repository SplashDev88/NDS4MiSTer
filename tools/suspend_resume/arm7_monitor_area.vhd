-- SPDX-License-Identifier: GPL-3.0-or-later
-- Equal externally retained guest buses for isolated mapping comparison.
-- MODE 0: default CPU; MODE 1: branch checkpoint; MODE 2: HALT+branch;
-- MODE 3: CPU-assisted monitor including private ROM/RAM and host transport.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
entity arm7_monitor_area is
  generic(MODE:natural:=0);
  port(clk,reset,ce,dma,irq,unhalt,new_halt:in std_logic;
    ss_addr:in std_logic_vector(27 downto 0);ss_data:in std_logic_vector(31 downto 0);
    ss_rnw,ss_ena,ss_rst:in std_logic;ss_be:in std_logic_vector(3 downto 0);
    state_data:out std_logic_vector(31 downto 0);state_done:out std_logic;
    req,restore,continue_run,release_run:in std_logic;active,paused,error,ready:out std_logic;
    mem_addr,mem_data:out std_logic_vector(31 downto 0);
    mem_read,mem_ena,mem_seq,mem_code:out std_logic;
    mem_acc:out std_logic_vector(1 downto 0);
    mem_input:in std_logic_vector(31 downto 0);mem_done:in std_logic;
    cpu_idle,halt:out std_logic;
    cpu_error,mem_lock,cpu_done,in_bios,jump:out std_logic;
    mem_low:out std_logic_vector(1 downto 0);
    last_read,dbg_pc:out std_logic_vector(31 downto 0);
    regsel:in unsigned(4 downto 0);regval:out std_logic_vector(31 downto 0);
    host_addr:in unsigned(5 downto 0);host_write:in std_logic;
    host_data:in std_logic_vector(31 downto 0);host_q:out std_logic_vector(31 downto 0));
end;
architecture rtl of arm7_monitor_area is
  signal ss:proc_bus_gb_type;
  function preset_only return std_logic is
  begin if MODE=1 or MODE=2 then return '0';else return '1';end if;end;
begin
  ss<=(ss_data,ss_addr,ss_rnw,ss_ena,"10",ss_be,ss_rst);
  monitor:if MODE=3 generate
    dut:entity work.nds_arm7_monitor_probe
      port map(clk=>clk,ce=>ce,reset=>reset,preset=>ss,addr=>mem_addr,rnw=>mem_read,
        ena=>mem_ena,seq=>mem_seq,code=>mem_code,acc=>mem_acc,dout=>mem_data,
        din=>mem_input,bus_done=>mem_done,dma=>dma,irq=>irq,new_halt=>new_halt,unhalt=>unhalt,
        idle=>cpu_idle,halted=>halt,request=>req,continue_run=>continue_run,restore=>restore,
        active=>active,paused=>paused,error=>error,host_addr=>host_addr,host_write=>host_write,
        host_din=>host_data,host_dout=>host_q,release_run=>release_run,ready=>ready,
        cpu_error=>cpu_error,lock=>mem_lock,cpu_done=>cpu_done,pc_in_bios=>in_bios,jump=>jump,
        lowbits=>mem_low,lastread=>last_read,dbg_pc=>dbg_pc,preset_q=>state_data,preset_done=>state_done,
        dbg_regsel=>regsel,dbg_regval=>regval);
  end generate;
  direct:if MODE/=3 generate
    dut:entity work.gba_cpu
      generic map(is_simu=>'0',SS_PRESET_ONLY=>preset_only,
        EXPERIMENTAL_CHECKPOINT=>MODE/=0,EXPERIMENTAL_HALT_CHECKPOINT=>MODE=2)
      port map(clk=>clk,ce=>ce,reset=>reset,savestate_bus=>ss,
        ss_wired_out=>state_data,ss_wired_done=>state_done,
        gb_bus_Adr=>mem_addr,gb_bus_dout=>mem_data,gb_bus_din=>mem_input,
        gb_bus_done=>mem_done,gb_bus_rnw=>mem_read,gb_bus_ena=>mem_ena,
        gb_bus_seq=>mem_seq,gb_bus_code=>mem_code,gb_bus_acc=>mem_acc,
        dma_on=>dma,CPU_bus_idle=>cpu_idle,PC_in_BIOS=>in_bios,cpu_halt=>halt,
        lastread=>last_read,jump_out=>jump,error_cpu=>cpu_error,IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt,
        gb_bus_lock=>mem_lock,bus_lowbits=>mem_low,done=>cpu_done,
        dbg_pc=>dbg_pc,dbg_regsel=>regsel,dbg_regval=>regval,
        checkpoint_req=>req,checkpoint_paused=>paused,checkpoint_restore=>restore);
    host_q<=(others=>'0');active<='0';ready<='0';error<='0';
  end generate;
end;
