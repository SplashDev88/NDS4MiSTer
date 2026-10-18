-- SPDX-License-Identifier: GPL-3.0-or-later
-- Isolated ARM9 CPU-assisted checkpoint experiment. NOT wired into the console.
-- Includes its own code ROM, snapshot RAM and guarded host transport so their
-- synthesis cost is measured. Guest RAM and guest exception vectors are unused.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
use work.pexport.all;
use work.nds_arm9_monitor_rom.all;
entity nds_arm9_monitor_probe is
  generic(ENABLED:boolean:=true; is_simu:std_logic:='0');
  port(clk,ce,reset:in std_logic;
    preset:in proc_bus_gb_type;
    addr:out std_logic_vector(31 downto 0);
    rnw,ena,seq,code:out std_logic;
    acc:out std_logic_vector(1 downto 0);
    dout:out std_logic_vector(31 downto 0);
    din:in std_logic_vector(31 downto 0); bus_done,dma,irq,new_halt,unhalt:in std_logic;
    idle,halted:out std_logic;
    request,continue_run,restore:in std_logic;
    -- Must certify the actual cache, TCM and external write path are drained.
    -- No default: an integrator must connect a real memory-owner receipt.
    memory_idle:in std_logic;
    cold_boot:in std_logic:='0';
    cp15_vector_hi,cp15_pu_enable,cp15_icache_ena,cp15_dcache_ena:out std_logic:='0';
    cp15_itcm_ena,cp15_itcm_load,cp15_dtcm_ena,cp15_dtcm_load:out std_logic:='0';
    cp15_dtcm_base:out std_logic_vector(31 downto 12):=(others=>'0');
    cp15_dtcm_size,cp15_itcm_size:out std_logic_vector(4 downto 0):=(others=>'0');
    bus_cacheable_i,bus_cacheable_d,bus_bufferable_d,bus_wdenied_d:out std_logic:='0';
    cache_op_ena:out std_logic:='0';
    cache_op:out std_logic_vector(3 downto 0):=(others=>'0');
    cache_op_addr:out std_logic_vector(31 downto 0):=(others=>'0');
    cache_op_busy:in std_logic;
    dbg_r0,dbg_lr,dbg_cpsr:out std_logic_vector(31 downto 0):=(others=>'0');
    active,paused,error:out std_logic;
    host_addr:in unsigned(5 downto 0);
    host_write:in std_logic;
    host_din:in std_logic_vector(31 downto 0);
    host_dout:out std_logic_vector(31 downto 0);
    release_run:in std_logic:='0';ready:out std_logic:='0';
    cpu_error,lock,cpu_done,pc_in_bios,jump:out std_logic:='0';
    lowbits:out std_logic_vector(1 downto 0):=(others=>'0');
    lastread,dbg_pc,preset_q:out std_logic_vector(31 downto 0):=(others=>'0');
    preset_done:out std_logic:='0';
    dbg_regsel:in unsigned(4 downto 0):=(others=>'0');
    dbg_regval:out std_logic_vector(31 downto 0):=(others=>'0')
    -- synthesis translate_off
    ;cpu_export_done:out std_logic:='0';cpu_export:out cpu_export_type:=export_init
    -- synthesis translate_on
  );
end;
architecture rtl of nds_arm9_monitor_probe is
  type ram_type is array(0 to 63) of std_logic_vector(31 downto 0);
  signal ram:ram_type; -- Deliberately uninitialized; capture writes all 64 words.
  attribute ramstyle:string;
  attribute ramstyle of ram:signal is "M10K";
  signal rom_q,ram_q,meta_q,private_data:std_logic_vector(31 downto 0);
  signal a,wd,rd,md:std_logic_vector(31 downto 0);
  signal wr,go,isc,complete,act,park,core_error,local_error:std_logic:='0';
  signal private_select,rom_select,ram_select,meta_select,meta_write:std_logic;
  signal private_done:std_logic:='0';
  signal response_kind:unsigned(1 downto 0):=(others=>'0');
  signal meta_address:unsigned(1 downto 0);
  signal cpu_ce:std_logic;
  signal host_access,ram_enable,ram_write:std_logic;
  signal ram_address:unsigned(5 downto 0);
  signal ram_data:std_logic_vector(31 downto 0);
begin
  cpu_ce<=ce and not local_error;
  cpu:entity work.nds_cpu9
    generic map(is_simu=>is_simu,SS_PRESET_ONLY=>'1',EXPERIMENTAL_CPU_MONITOR=>ENABLED)
    port map(clk=>clk,ce=>cpu_ce,reset=>reset,cold_boot=>cold_boot,savestate_bus=>preset,
      ss_wired_done=>preset_done,ss_wired_out=>preset_q,gb_bus_Adr=>a,gb_bus_rnw=>wr,gb_bus_ena=>go,
      gb_bus_seq=>seq,gb_bus_code=>isc,gb_bus_acc=>acc,gb_bus_dout=>wd,
      gb_bus_din=>rd,gb_bus_done=>complete,dma_on=>dma,CPU_bus_idle=>idle,
      PC_in_BIOS=>pc_in_bios,cpu_halt=>halted,lastread=>lastread,jump_out=>jump,
      error_cpu=>cpu_error,gb_bus_lock=>lock,bus_lowbits=>lowbits,done=>cpu_done,
      dbg_pc=>dbg_pc,dbg_regsel=>dbg_regsel,dbg_regval=>dbg_regval,
      -- synthesis translate_off
      cpu_export_done=>cpu_export_done,cpu_export=>cpu_export,
      -- synthesis translate_on
      IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt,
      cp15_vector_hi=>cp15_vector_hi,cp15_pu_enable=>cp15_pu_enable,
      cp15_icache_ena=>cp15_icache_ena,cp15_dcache_ena=>cp15_dcache_ena,
      cp15_itcm_ena=>cp15_itcm_ena,cp15_itcm_load=>cp15_itcm_load,
      cp15_dtcm_ena=>cp15_dtcm_ena,cp15_dtcm_load=>cp15_dtcm_load,
      cp15_dtcm_base=>cp15_dtcm_base,cp15_dtcm_size=>cp15_dtcm_size,cp15_itcm_size=>cp15_itcm_size,
      bus_cacheable_i=>bus_cacheable_i,bus_cacheable_d=>bus_cacheable_d,
      bus_bufferable_d=>bus_bufferable_d,bus_wdenied_d=>bus_wdenied_d,
      cache_op_ena=>cache_op_ena,cache_op=>cache_op,cache_op_addr=>cache_op_addr,
      cache_op_busy=>cache_op_busy,dbg_r0=>dbg_r0,dbg_lr=>dbg_lr,dbg_cpsr=>dbg_cpsr,
      monitor_request=>request,monitor_memory_idle=>memory_idle,monitor_continue=>continue_run,monitor_restore=>restore,
      monitor_release=>release_run,monitor_ready=>ready,
      monitor_active=>act,monitor_paused=>park,monitor_error=>core_error,
      monitor_meta_address=>meta_address,monitor_meta_write=>meta_write,
      monitor_meta_din=>wd,monitor_meta_dout=>md);
  active<=act;paused<=park;error<=core_error or local_error;
  addr<=a;rnw<=wr;code<=isc;dout<=wd;
  -- This mux is BEFORE the ordinary memory decoder/cache/TCM. CP15 may
  -- deny or remap 0F000000; maintenance never reaches those guest owners.
  -- A live guest access to this address is still a normal guest bus operation.
  private_select<=act when ENABLED else '0';
  ena<=go and not private_select;
  complete<=private_done when private_select='1' else bus_done;
  rd<=private_data when private_select='1' else din;
  rom_select<='1' when a(31 downto 11)=std_logic_vector(to_unsigned(16#0F000000#/2048,21)) else '0';
  ram_select<='1' when a(31 downto 8)=x"0F0008" else '0';
  meta_select<='1' when a(31 downto 4)=x"0F000F1" else '0';
  meta_address<=unsigned(a(3 downto 2));
  meta_write<=go and act and not wr and meta_select;
  private_data<=rom_q when response_kind=0 else ram_q when response_kind=1 else meta_q;
  -- CPU and host never need concurrent access. One physical RAM port avoids
  -- synthesizing priority between two write ports into thousands of flops.
  host_access<=park or (reset and restore);
  ram_address<=host_addr when host_access='1' else unsigned(a(7 downto 2));
  ram_data<=host_din when host_access='1' else wd;
  ram_enable<=host_access or (go and act and ram_select);
  ram_write<=host_write and reset and restore when host_access='1' else
             go and act and ram_select and not wr and not reset;
  gen_memory:if ENABLED generate
    host_dout<=ram_q when host_access='1' else (others=>'0');
    process(clk) begin
      if rising_edge(clk) then
        if go='1' and act='1' then
          rom_q<=MONITOR_ROM(to_integer(unsigned(a(10 downto 2))));
          meta_q<=md;
        end if;
        if ram_enable='1' then
          ram_q<=ram(to_integer(ram_address));
          if ram_write='1' then ram(to_integer(ram_address))<=ram_data;end if;
        end if;
      end if;
    end process;
    process(clk) begin
      if rising_edge(clk) then
        if ce='1' then private_done<='0';end if;
        if reset='1' then private_done<='0';local_error<='0';
        elsif go='1' and act='1' then
          private_done<='1';
          if rom_select='1' and wr='1' then response_kind<=to_unsigned(0,2);
          elsif ram_select='1' and isc='0' then response_kind<=to_unsigned(1,2);
          elsif meta_select='1' and isc='0' and a(3 downto 2)/="11" then response_kind<=to_unsigned(2,2);
          else local_error<='1';end if;
        end if;
      end if;
    end process;
  end generate;
  no_memory:if not ENABLED generate
    host_dout<=(others=>'0');private_done<='0';local_error<='0';
  end generate;
end;
