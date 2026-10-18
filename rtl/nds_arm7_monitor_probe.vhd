-- SPDX-License-Identifier: GPL-3.0-or-later
-- Isolated ARM7 CPU-assisted checkpoint experiment. NOT wired into the console.
-- Includes its own code ROM, snapshot RAM and guarded host transport so their
-- synthesis cost is measured. Guest RAM and guest exception vectors are unused.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.pProc_bus_gba.all;
use work.pexport.all;
use work.nds_arm7_monitor_rom.all;
entity nds_arm7_monitor_probe is
  generic(ENABLED:boolean:=true; is_simu:std_logic:='0'; SLEEP_ENABLED:boolean:=false);
  port(clk,ce,reset:in std_logic;
    preset:in proc_bus_gb_type;
    addr:out std_logic_vector(31 downto 0);
    rnw,ena,seq,code:out std_logic;
    acc:out std_logic_vector(1 downto 0);
    dout:out std_logic_vector(31 downto 0);
    din:in std_logic_vector(31 downto 0); bus_done,dma,irq,new_halt,unhalt:in std_logic;
    idle,halted:out std_logic;
    request,continue_run,restore:in std_logic;
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
architecture rtl of nds_arm7_monitor_probe is
  constant ADDRESS_BITS:positive:=host_addr'length;
  type ram_type is array(0 to 2**ADDRESS_BITS-1) of std_logic_vector(31 downto 0);
  signal ram:ram_type; -- Deliberately uninitialized; capture writes all 45 words.
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
  signal ram_address:unsigned(ADDRESS_BITS-1 downto 0);
  signal ram_data:std_logic_vector(31 downto 0);
  signal pipe_capture,pipe_restore,pipe_busy,pipe_ram_write,pipe_ram_enable:std_logic:='0';
  signal pipe_write,pipe_captured,pipe_loaded:std_logic:='0';
  signal pipe_address:unsigned(3 downto 0):=(others=>'0');
  signal pipe_data:std_logic_vector(31 downto 0);
begin
  pipe_transfer:if SLEEP_ENABLED and ENABLED generate
    transfer:entity work.nds_monitor_pipeline_transfer
      port map(clk=>clk,reset=>reset,capture=>pipe_capture,restore=>pipe_restore,
        busy=>pipe_busy,ram_write=>pipe_ram_write,ram_enable=>pipe_ram_enable,
        address=>pipe_address,cpu_write=>pipe_write,captured=>pipe_captured,loaded=>pipe_loaded);
  end generate;
  no_pipe_transfer:if not SLEEP_ENABLED or not ENABLED generate
    pipe_busy<='0';pipe_ram_write<='0';pipe_ram_enable<='0';pipe_write<='0';
    pipe_captured<='0';pipe_loaded<='0';pipe_address<=(others=>'0');
  end generate;
  cpu_ce<=ce and not local_error;
  -- External DMA owns only the guest bus; maintenance uses private storage.
  cpu:entity work.gba_cpu
    generic map(is_simu=>is_simu,SS_PRESET_ONLY=>'1',EXPERIMENTAL_CPU_MONITOR=>ENABLED,
      EXPERIMENTAL_MONITOR_SLEEP=>SLEEP_ENABLED and ENABLED)
    port map(clk=>clk,ce=>cpu_ce,reset=>reset,savestate_bus=>preset,
      ss_wired_done=>preset_done,ss_wired_out=>preset_q,gb_bus_Adr=>a,gb_bus_rnw=>wr,gb_bus_ena=>go,
      gb_bus_seq=>seq,gb_bus_code=>isc,gb_bus_acc=>acc,gb_bus_dout=>wd,
      gb_bus_din=>rd,gb_bus_done=>complete,dma_on=>dma and not act,CPU_bus_idle=>idle,
      PC_in_BIOS=>pc_in_bios,cpu_halt=>halted,lastread=>lastread,jump_out=>jump,
      error_cpu=>cpu_error,gb_bus_lock=>lock,bus_lowbits=>lowbits,done=>cpu_done,
      dbg_pc=>dbg_pc,dbg_regsel=>dbg_regsel,dbg_regval=>dbg_regval,
      -- synthesis translate_off
      cpu_export_done=>cpu_export_done,cpu_export=>cpu_export,
      -- synthesis translate_on
      IRQ_in=>irq,unhalt=>unhalt,new_halt=>new_halt,
      monitor_request=>request,monitor_continue=>continue_run,monitor_restore=>restore,
      monitor_release=>release_run,monitor_ready=>ready,
      monitor_pipeline_capture=>pipe_capture,monitor_pipeline_restore=>pipe_restore,
      monitor_pipeline_address=>pipe_address,monitor_pipeline_dout=>pipe_data,
      monitor_pipeline_write=>pipe_write,monitor_pipeline_din=>ram_q,
      monitor_pipeline_copied=>pipe_captured,monitor_pipeline_loaded=>pipe_loaded,
      monitor_active=>act,monitor_paused=>park,monitor_error=>core_error,
      monitor_meta_address=>meta_address,monitor_meta_write=>meta_write,
      monitor_meta_din=>wd,monitor_meta_dout=>md);
  active<=act;paused<=park;error<=core_error or local_error;
  addr<=a;rnw<=wr;code<=isc;dout<=wd;
  -- A live guest access to this address is still a normal guest bus operation.
  private_select<=act when ENABLED else '0';
  ena<=go and not private_select;
  complete<=private_done when private_select='1' else bus_done;
  rd<=private_data when private_select='1' else din;
  rom_select<='1' when a(31 downto 11)=std_logic_vector(to_unsigned(16#0F000000#/2048,21)) else '0';
  ram_select<='1' when unsigned(a(31 downto ADDRESS_BITS+2))=to_unsigned(16#0F000800#/(2**(ADDRESS_BITS+2)),30-ADDRESS_BITS) else '0';
  meta_select<='1' when a(31 downto 4)=x"0F000F1" else '0';
  meta_address<=unsigned(a(3 downto 2));
  meta_write<=go and act and not wr and meta_select;
  private_data<=rom_q when response_kind=0 else ram_q when response_kind=1 else meta_q;
  -- CPU and host never need concurrent access. One physical RAM port avoids
  -- synthesizing priority between two write ports into thousands of flops.
  host_access<=park or (reset and restore);
  ram_address<=to_unsigned(45,ADDRESS_BITS)+resize(pipe_address,ADDRESS_BITS) when pipe_busy='1' else
               host_addr when host_access='1' else unsigned(a(ADDRESS_BITS+1 downto 2));
  ram_data<=pipe_data when pipe_busy='1' else host_din when host_access='1' else wd;
  ram_enable<=pipe_ram_enable when pipe_busy='1' else host_access or (go and act and ram_select);
  ram_write<=pipe_ram_write when pipe_busy='1' else
             host_write and reset and restore when host_access='1' else
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
          else
            -- synthesis translate_off
            report "illegal private monitor access "&to_hstring(a)&" code="&std_logic'image(isc)&" read="&std_logic'image(wr) severity warning;
            -- synthesis translate_on
            local_error<='1';
          end if;
        end if;
      end if;
    end process;
  end generate;
  no_memory:if not ENABLED generate
    host_dout<=(others=>'0');private_done<='0';local_error<='0';
  end generate;
end;
