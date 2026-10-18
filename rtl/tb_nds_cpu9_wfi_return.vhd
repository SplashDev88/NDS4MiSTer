-- Synthetic BL -> WFI -> BX caller-return regression for the production CPU.
-- Sweep bus latency and wake phase to expose IRQ selection on the edge that
-- clears halt. The post-WFI BX must execute; falling through stores a failure
-- marker. No game image, BIOS, save file, or external data is needed.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu9_wfi_return is
  generic(READ_DELAY: positive:=1; WAKE_DELAY: natural:=4;
          IRQ_ENABLED: boolean:=true; CHECKPOINT_OPERATION:string:="none";
          OMIT_PIPELINE_RESTORE:boolean:=false; MUTATE_PREFETCH:boolean:=false);
end;
architecture sim of tb_nds_cpu9_wfi_return is
  signal clk: std_logic:='0';
  signal reset: std_logic:='1';
  signal ss: proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc: std_logic_vector(31 downto 0);
  signal ena,done,code,rnw,halt: std_logic:='0';
  signal irq,wake: std_logic:='0';
  signal finished,vector_seen: boolean:=false;
  signal changed_memory:boolean:=false;
  signal checkpoint_req,checkpoint_paused,checkpoint_restore,cpu_idle:std_logic:='0';
  signal ssout:std_logic_vector(31 downto 0);signal ssdone:std_logic;
  type checkpoint_words is array(0 to 79) of std_logic_vector(31 downto 0);
  function checkpoint_preset return std_logic is
  begin if CHECKPOINT_OPERATION="none" then return '1';else return '0';end if;end;
  function word_address(i:natural) return natural is
  begin
    if i<47 then return i;elsif i<68 then return 128+i-47;else return 160+i-68;end if;
  end;
begin
  clk<=not clk after 5 ns;
  dut: entity work.nds_cpu9
    generic map(is_simu=>'0',SS_PRESET_ONLY=>checkpoint_preset,
      EXPERIMENTAL_CHECKPOINT=>CHECKPOINT_OPERATION/="none",
      EXPERIMENTAL_HALT_CHECKPOINT=>CHECKPOINT_OPERATION/="none")
    port map(clk=>clk,ce=>'1',reset=>reset,dbg_pc=>pc,
      savestate_bus=>ss,ss_wired_out=>ssout,ss_wired_done=>ssdone,gb_bus_Adr=>addr,gb_bus_rnw=>rnw,
      gb_bus_ena=>ena,gb_bus_seq=>open,gb_bus_code=>code,gb_bus_acc=>open,
      gb_bus_dout=>dout,gb_bus_din=>din,gb_bus_done=>done,dma_on=>'0',
      CPU_bus_idle=>cpu_idle,PC_in_BIOS=>open,cpu_halt=>halt,lastread=>open,jump_out=>open,
      IRQ_in=>irq,unhalt=>wake,new_halt=>'0',cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,cp15_itcm_load=>open,
      cp15_dtcm_ena=>open,cp15_dtcm_load=>open,cp15_dtcm_base=>open,cp15_dtcm_size=>open,
      cp15_itcm_size=>open,bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0',
      checkpoint_req=>checkpoint_req,checkpoint_paused=>checkpoint_paused,
      checkpoint_restore=>checkpoint_restore);
  process(clk)
    variable remaining:natural:=0;
    variable pending:std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      done<='0';
      if remaining>0 then
        remaining:=remaining-1;
        if remaining=0 then done<='1';din<=pending;end if;
      end if;
      if ena='1' then
        assert remaining=0 report "overlapping memory request" severity failure;
        remaining:=READ_DELAY;
        if rnw='0' then
          pending:=(others=>'0');
          assert dout/=x"000000DE"
            report "FAIL: executed terminal guard after skipping WFI return" severity failure;
          if dout=x"00000055" then finished<=true;end if;
        else
          case addr is
            when x"02000000"=>
              if IRQ_ENABLED then pending:=x"E321F01F";else pending:=x"E321F09F";end if;
            when x"02000004"=>pending:=x"E3A0DA02";
            when x"02000008"=>pending:=x"E1A00000";
            when x"0200000C"=>pending:=x"E92D4000";
            when x"02000010"=>pending:=x"E24DD004";
            when x"02000014"=>pending:=x"E1A00000";
            when x"02000018"=>pending:=x"EB0003F8"; -- BL WFI helper; LR=0x0200001c
            when x"0200001C"=>pending:=x"E3A02055"; -- success marker after return
            when x"02000020"=>pending:=x"E58D2000";
            when x"02000024"=>pending:=x"EAFFFFFE";
            when x"02001000"=>pending:=x"E3A00000";
            when x"02001004"=>pending:=x"EE070F90";
            when x"02001008"=>
              -- After capture, change RAM at the already decoded BX. A
              -- masked wake must execute its saved opcode, not refetch RAM.
              if changed_memory then pending:=x"E3A020DE";
              else pending:=x"E12FFF1E";end if;
            when x"0200100C"=>pending:=x"E3A020DE";
            when x"02001010"=>pending:=x"E58D2000";
            when x"02001014"=>pending:=x"EAFFFFFE";
            when x"FFFF0018"=>pending:=x"E25EF004";vector_seen<=true;
            when others=>pending:=x"E1A00000";
          end case;
        end if;
      end if;
    end if;
  end process;
  process
    file state_file:text;
    variable linebuf:line;
    variable saved,reread:checkpoint_words;
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure read_state(variable v:out checkpoint_words) is
    begin
      for i in v'range loop
        ss.Adr<=std_logic_vector(to_unsigned(word_address(i),ss.Adr'length));
        ss.rnw<='1';ss.ena<='1';clocks(1);
        assert ssdone='1' report "checkpoint state word missing" severity failure;
        v(i):=ssout;
      end loop;ss.ena<='0';
    end;
  begin
    wait for 40 ns;wait until falling_edge(clk);
    if CHECKPOINT_OPERATION="restore" then
      ss.rst<='1';clocks(3);ss.rst<='0';checkpoint_restore<='1';clocks(2);
      file_open(state_file,"halt.state",read_mode);
      for i in saved'range loop
        readline(state_file,linebuf);hread(linebuf,saved(i));
        if not OMIT_PIPELINE_RESTORE or word_address(i)<160 then
          ss.Adr<=std_logic_vector(to_unsigned(word_address(i),ss.Adr'length));
          ss.Din<=saved(i);ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(1);
        end if;
      end loop;
      assert endfile(state_file) report "trailing checkpoint words" severity failure;
      file_close(state_file);clocks(3);read_state(reread);
      for i in 1 to saved'high loop
        if not OMIT_PIPELINE_RESTORE or word_address(i)<160 then
          assert saved(i)=reread(i) report "ARM9 checkpoint state mismatch" severity failure;
        end if;
      end loop;
      checkpoint_restore<='0';
      changed_memory<=MUTATE_PREFETCH;
    else
      ss.Din<=x"02000000";ss.ena<='1';clocks(2);ss.ena<='0';clocks(4);
    end if;
    reset<='0';
    if halt/='1' then wait until halt='1' for 20 us;end if;
    assert halt='1' report "did not reach WFI" severity failure;
    for n in 1 to WAKE_DELAY loop wait until falling_edge(clk);end loop;
    if CHECKPOINT_OPERATION="capture" then
      checkpoint_req<='1';
      for i in 1 to 2000 loop clocks(1);exit when checkpoint_paused='1';end loop;
      assert checkpoint_paused='1' report "WFI checkpoint timed out" severity failure;
      assert cpu_idle='1' and ena='0' report "WFI snapshot has pending bus work" severity failure;
      read_state(saved);clocks(100);read_state(reread);
      assert saved=reread report "WFI checkpoint changed while held" severity failure;
      file_open(state_file,"halt.state",write_mode);
      for i in saved'range loop hwrite(linebuf,saved(i));writeline(state_file,linebuf);end loop;
      file_close(state_file);changed_memory<=MUTATE_PREFETCH;
      checkpoint_req<='0';clocks(8);
    end if;
    wake<='1';irq<='1';
    if IRQ_ENABLED then
      wait until vector_seen for 20 us;
      assert vector_seen report "did not enter IRQ" severity failure;
    else
      wait for 200 ns;
    end if;
    wait until falling_edge(clk);irq<='0';wake<='0';
    if not finished then wait until finished for 20 us;end if;
    assert finished report "did not return to caller after WFI/IRQ" severity failure;
    assert vector_seen=IRQ_ENABLED report "unexpected IRQ vector state" severity failure;
    report "PASS: ARM9 WFI/BX caller return, delay=" & integer'image(READ_DELAY) &
      " wake=" & integer'image(WAKE_DELAY) & " IRQ-enabled=" & boolean'image(IRQ_ENABLED);
    stop;wait;
  end process;
end;
