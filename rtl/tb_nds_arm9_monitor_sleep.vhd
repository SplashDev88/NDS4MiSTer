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
entity tb_nds_arm9_monitor_sleep is
  generic(READ_DELAY:positive:=1; WAKE_DELAY:natural:=4;
          IRQ_ENABLED:boolean:=true; OPERATION:string:="capture";
          MUTATE_PREFETCH:boolean:=false; CORRUPT_WORD:integer:=-1;
          EXPECT_REJECT:boolean:=false; WAKE_PHASE:natural:=0);

end;
architecture sim of tb_nds_arm9_monitor_sleep is
  signal clk: std_logic:='0';
  signal reset: std_logic:='1';
  signal ss: proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc: std_logic_vector(31 downto 0);
  signal ena,done,code,rnw,halt: std_logic:='0';
  signal irq,wake: std_logic:='0';
  signal finished,vector_seen: boolean:=false;
  signal changed_memory:boolean:=false;
  signal checkpoint_req,checkpoint_paused,checkpoint_restore,cpu_idle:std_logic:='0';
  signal monitor_active,monitor_paused,monitor_error,ready,cont,release_run,hw:std_logic:='0';
  signal ha:unsigned(6 downto 0):=(others=>'0');
  signal hdin,hdout:std_logic_vector(31 downto 0):=(others=>'0');
  type checkpoint_words is array(0 to 77) of std_logic_vector(31 downto 0);
begin
  clk<=not clk after 5 ns;
  dut:entity work.nds_arm9_monitor_probe generic map(SLEEP_ENABLED=>true)
    port map(clk=>clk,ce=>'1',reset=>reset,preset=>ss,addr=>addr,rnw=>rnw,ena=>ena,seq=>open,
      code=>code,acc=>open,dout=>dout,din=>din,bus_done=>done,dma=>'0',irq=>irq,
      new_halt=>'0',unhalt=>wake,idle=>cpu_idle,halted=>halt,dbg_pc=>pc,
      memory_idle=>'1',cache_op_busy=>'0',request=>checkpoint_req,continue_run=>cont,restore=>checkpoint_restore,
      active=>monitor_active,paused=>monitor_paused,error=>monitor_error,
      host_addr=>ha,host_write=>hw,host_din=>hdin,host_dout=>hdout,release_run=>release_run,ready=>ready);
  process(clk)
    variable remaining:natural:=0;
    variable pending:std_logic_vector(31 downto 0);
  begin
    if rising_edge(clk) then
      done<='0';
      assert monitor_error='0' or EXPECT_REJECT report "WFI monitor error" severity failure;
      assert monitor_active='0' or ena='0' report "WFI monitor leaked guest access" severity failure;
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
    begin for i in v'range loop ha<=to_unsigned(i,7);clocks(2);v(i):=hdout;end loop;end;
    procedure await_ready is
    begin
      for i in 1 to 50000 loop clocks(1);exit when ready='1' or monitor_error='1';end loop;
      if EXPECT_REJECT then
        assert monitor_error='1' and ready='0' and monitor_active='1' report "bad WFI image was accepted" severity failure;
        clocks(100);assert ena='0' and not finished report "bad WFI image reached guest" severity failure;
        report "PASS: invalid WFI pipeline rejected";stop;wait;
      end if;
      assert ready='1' and halt='1' and monitor_paused='1' and monitor_active='1'
        report "restored WFI pipeline missing at return hold" severity failure;
      if WAKE_PHASE=2 then irq<='1';wake<='1';end if;
      cont<='1';clocks(100);cont<='0';
      assert ready='1' and halt='1' and ena='0' and not finished
        report "WFI context escaped before common release" severity failure;
      release_run<='1';clocks(1);release_run<='0';clocks(2);
      assert monitor_active='0' and (halt='1' or WAKE_PHASE/=0) report "WFI lost on common release" severity failure;
    end;
  begin
    wait for 40 ns;wait until falling_edge(clk);
    ss.rst<='1';clocks(3);ss.rst<='0';clocks(2);
    ss.Din<=x"02000000";ss.ena<='1';clocks(2);ss.ena<='0';clocks(4);
    if OPERATION="restore" then
      checkpoint_restore<='1';clocks(2);file_open(state_file,"arm9-monitor-sleep.state",read_mode);
      for i in saved'range loop
        readline(state_file,linebuf);hread(linebuf,saved(i));
        if i=CORRUPT_WORD then
          if EXPECT_REJECT and i=64 then saved(i):=x"00000002";
          elsif EXPECT_REJECT and i=68 then saved(i)(7 downto 5):="111";
          elsif i=68 then saved(i):=saved(i) xor x"02000000"; -- change decoded BX source register
          else saved(i):=saved(i) xor x"00000080";end if;
        end if;
        ha<=to_unsigned(i,7);hdin<=saved(i);hw<='1';clocks(1);
      end loop;hw<='0';file_close(state_file);clocks(4);
      changed_memory<=MUTATE_PREFETCH;reset<='0';clocks(1);checkpoint_restore<='0';
      if WAKE_PHASE=1 then irq<='1';wake<='1';end if;
      await_ready;
    else
      reset<='0';wait until halt='1' for 100 us;assert halt='1' report "did not reach WFI" severity failure;
      clocks(WAKE_DELAY);checkpoint_req<='1';
      for i in 1 to 50000 loop clocks(1);exit when monitor_paused='1';end loop;
      assert monitor_paused='1' and ready='0' and cpu_idle='1' report "WFI monitor capture timed out" severity failure;
      read_state(saved);clocks(100);read_state(reread);
      assert saved=reread and saved(64)=x"00000001" report "WFI image missing or unstable" severity failure;
      file_open(state_file,"arm9-monitor-sleep.state",write_mode);
      for i in saved'range loop hwrite(linebuf,saved(i));writeline(state_file,linebuf);end loop;file_close(state_file);
      changed_memory<=MUTATE_PREFETCH;checkpoint_req<='0';cont<='1';clocks(1);cont<='0';
      if WAKE_PHASE=1 then irq<='1';wake<='1';end if;
      await_ready;
    end if;
    wake<='1';irq<='1';
    if IRQ_ENABLED then
      if not vector_seen then wait until vector_seen for 20 us;end if;
      assert vector_seen report "did not enter IRQ" severity failure;
    else
      wait for 200 ns;
    end if;
    wait until falling_edge(clk);irq<='0';wake<='0';
    if not finished then wait until finished for 20 us;end if;
    assert finished report "did not return to caller after WFI/IRQ" severity failure;
    assert vector_seen=IRQ_ENABLED report "unexpected IRQ vector state" severity failure;
    report "PASS: CPU-assisted WFI capture/restore returns through BX, delay=" & integer'image(READ_DELAY) &
      " wake=" & integer'image(WAKE_DELAY) & " IRQ-enabled=" & boolean'image(IRQ_ENABLED);
    stop;wait;
  end process;
  process begin wait for 10 ms;assert false report "WFI monitor watchdog" severity failure;end process;
end;
