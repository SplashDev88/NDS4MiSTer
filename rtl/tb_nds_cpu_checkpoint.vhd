-- SPDX-License-Identifier: GPL-3.0-or-later
-- CPU component proof, NOT a console save state. Authored ARM code only.
-- Capture and restore use separate simulator processes and one state file.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_cpu_checkpoint is
  generic(OPERATION:string:="capture"; READ_DELAY:positive:=1;
          REQUEST_PHASE:natural:=0; OMIT_EXT_RESTORE:boolean:=false;
          ARM9:boolean:=true; THUMB_LOOP:boolean:=false; STEP_PERIOD:positive:=1;
          EARLY_CAPTURE:boolean:=false; HALT_PIPELINE:boolean:=false);
end;
architecture sim of tb_nds_cpu_checkpoint is
  signal clk:std_logic:='0'; signal ce,dma:std_logic:='0'; signal reset:std_logic:='1';
  signal req,paused,restoring,ena,done,rnw,code,idle,ssdone:std_logic:='0';
  signal addr,din,dout,ssout:std_logic_vector(31 downto 0);
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal completed,initial_count,writes:natural:=0;
  signal pending_bus:boolean:=false;
  function last_word return natural is
    variable result:natural:=47;
  begin
    if ARM9 then result:=67;end if;
    if HALT_PIPELINE then result:=result+12;end if;
    return result;
  end;
  function expected_flags return std_logic_vector is
  begin if ARM9 then return x"0800009F"; else return x"0000009F"; end if; end;
  type state_words is array(0 to last_word) of std_logic_vector(31 downto 0);
  function word_address(i:natural) return natural is
  begin
    if i<47 then return i;
    elsif ARM9 and i<68 then return 128+i-47;
    elsif not ARM9 and i=47 then return 148;
    elsif ARM9 then return 160+i-68;
    else return 160+i-48;end if;
  end;
  function instruction(a:std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    case a is
      when x"02000000"=>return x"E321F09F"; -- masked System
      when x"02000004"=>return x"E3A00301"; -- output base 04000000
      when x"02000008"=>return x"E3A01000"; -- counter=0
      when x"0200000C"=>
        if ARM9 then return x"E328F302"; else return x"E1A00000"; end if; -- CPSR_f.Q=1
      when x"02000010"=>return x"E3A03055";
      when x"02000014"=>
        if ARM9 then return x"EE0D3F10"; else return x"E1A00000"; end if; -- CP15 PID=55
      when x"02000018"=>return x"E3A03007";
      when x"0200001C"=>
        if ARM9 then return x"EE093F10"; else return x"E1A00000"; end if; -- D-cache lockdown=7
      when x"02000020"=>return x"E2811001"; -- ++counter
      when x"02000024"=>return x"E5801000"; -- publish counter
      when x"02000028"=>return x"E10F2000"; -- MRS r2,CPSR
      when x"0200002C"=>return x"E5802004"; -- publish flags/mode
      when x"02000030"=>
        if ARM9 then return x"EE1D3F10"; else return x"E3A03055"; end if; -- MRC r3,CP15 PID
      when x"02000034"=>return x"E5803008"; -- publish PID
      when x"02000038"=>
        if THUMB_LOOP then return x"E28F4001"; else return x"EBFFFFF8"; end if; -- BL checks LR retirement
      when x"0200003C"=>return x"E12FFF14"; -- BX r4 -> Thumb 02000040
      when x"02000040"=>return x"00003101"; -- adds r1,#1
      when x"02000042"=>return x"00006001"; -- str r1,[r0]
      when x"02000044"=>return x"00006042"; -- str r2,[r0,#4]
      when x"02000046"=>return x"00006083"; -- str r3,[r0,#8]
      when x"02000048"=>return x"0000E7FA"; -- b 02000040
      when others=>return x"E1A00000";
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  process
  begin
    for i in 1 to STEP_PERIOD loop
      wait until falling_edge(clk);
      if i=STEP_PERIOD then ce<='1'; else ce<='0'; end if;
    end loop;
  end process;
  garm9:if ARM9 generate
  dut:entity work.nds_cpu9
    generic map(is_simu=>'0',SS_PRESET_ONLY=>'0',EXPERIMENTAL_CHECKPOINT=>true,
      EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
    port map(clk=>clk,ce=>ce,reset=>reset,savestate_bus=>ss,
      ss_wired_out=>ssout,ss_wired_done=>ssdone,
      gb_bus_Adr=>addr,gb_bus_rnw=>rnw,gb_bus_ena=>ena,gb_bus_seq=>open,
      gb_bus_code=>code,gb_bus_acc=>open,gb_bus_dout=>dout,gb_bus_din=>din,
      gb_bus_done=>done,dma_on=>dma,CPU_bus_idle=>idle,PC_in_BIOS=>open,
      cpu_halt=>open,lastread=>open,jump_out=>open,IRQ_in=>'0',unhalt=>'0',
      new_halt=>'0',cp15_vector_hi=>open,cp15_pu_enable=>open,
      cp15_icache_ena=>open,cp15_dcache_ena=>open,cp15_itcm_ena=>open,
      cp15_itcm_load=>open,cp15_dtcm_ena=>open,cp15_dtcm_load=>open,
      cp15_dtcm_base=>open,cp15_dtcm_size=>open,cp15_itcm_size=>open,
      bus_cacheable_i=>open,bus_cacheable_d=>open,cache_op_busy=>'0',
      checkpoint_req=>req,checkpoint_paused=>paused,checkpoint_restore=>restoring);
  end generate;
  garm7:if not ARM9 generate
    dut:entity work.gba_cpu
      generic map(is_simu=>'0',SS_PRESET_ONLY=>'0',EXPERIMENTAL_CHECKPOINT=>true,
        EXPERIMENTAL_HALT_CHECKPOINT=>HALT_PIPELINE)
      port map(clk=>clk,ce=>ce,reset=>reset,savestate_bus=>ss,
        ss_wired_out=>ssout,ss_wired_done=>ssdone,
        gb_bus_Adr=>addr,gb_bus_rnw=>rnw,gb_bus_ena=>ena,gb_bus_seq=>open,
        gb_bus_code=>code,gb_bus_acc=>open,gb_bus_dout=>dout,gb_bus_din=>din,
        gb_bus_done=>done,dma_on=>dma,CPU_bus_idle=>idle,PC_in_BIOS=>open,
        cpu_halt=>open,lastread=>open,jump_out=>open,IRQ_in=>'0',unhalt=>'0',
        new_halt=>'0',checkpoint_req=>req,checkpoint_paused=>paused,checkpoint_restore=>restoring);
  end generate;
  process(clk)
    variable pending:boolean:=false;
    variable remaining:natural:=0;
    variable payload:std_logic_vector(31 downto 0);
    variable count,lane:natural:=0;
  begin
    if rising_edge(clk) then
      if ce='1' then done<='0'; end if;
      if reset='1' then
        assert not pending report "reset discarded an outstanding bus operation" severity failure;
        count:=initial_count;completed<=count;lane:=0;writes<=0;
      else
        if pending then
          if remaining=0 then done<='1';din<=payload;pending:=false;
          else remaining:=remaining-1;end if;
        end if;
        if ena='1' then
          assert not pending report "overlapping bus request" severity failure;
          pending:=true;remaining:=READ_DELAY-1;payload:=instruction(addr);
          if rnw='0' then
            assert code='0' report "write marked as instruction" severity failure;
            case lane is
              when 0=>
                count:=count+1;
                assert addr=x"04000000" and unsigned(dout)=count
                  report "resume skipped or duplicated a store" severity failure;
                completed<=count;
              when 1=>
                assert addr=x"04000004" and dout=expected_flags
                  report "CPSR/Q did not survive resume" severity failure;
              when others=>
                assert addr=x"04000008" and dout=x"00000055"
                  report "CP15 PID did not survive resume" severity failure;
            end case;
            lane:=(lane+1) mod 3;writes<=writes+1;
          end if;
        end if;
      end if;
      pending_bus<=pending;
    end if;
  end process;
  process
    file capsule:text;
    variable linebuf:line;
    variable saved,reread:state_words;
    variable before:natural;
    variable seed:std_logic_vector(31 downto 0);
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure put(a:natural;v:std_logic_vector(31 downto 0)) is
    begin
      ss.Adr<=std_logic_vector(to_unsigned(a,ss.Adr'length));ss.Din<=v;
      ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(1);
    end;
    procedure read_state(variable v:out state_words) is
    begin
      for i in v'range loop
        ss.Adr<=std_logic_vector(to_unsigned(word_address(i),ss.Adr'length));
        ss.rnw<='1';ss.ena<='1';clocks(1);
        assert ssdone='1' report "state word not implemented" severity failure;
        v(i):=ssout;
      end loop;ss.ena<='0';
    end;
    procedure pause_cpu is
    begin
      req<='1';
      for i in 1 to 2000 loop clocks(1);exit when paused='1';end loop;
      assert paused='1' report "checkpoint request timed out" severity failure;
      assert idle='1' and ena='0' and not pending_bus
        report "checkpoint acknowledged before CPU bus drained" severity failure;
    end;
  begin
    ss.rst<='1';clocks(4);ss.rst<='0';clocks(2);
    if OPERATION="capture" then
      restoring<='1';clocks(1);
      -- Distinct inactive banks detect omissions beyond r0..r15.
      for i in 19 to 45 loop put(i,std_logic_vector(to_unsigned(i*257,32)));end loop;
      if ARM9 then
        -- Keep control/TCM boot mappings, but make every other saved CP15
        -- register differ from reset defaults. Guest code then changes PID,
        -- lockdown and Q again before the checkpoint.
        put(128,x"00012078");put(129,x"0300000A");put(130,x"00000020");
        for i in 3 to 18 loop
          put(128+i,std_logic_vector(to_unsigned(16#01230000#+i*257,32)));
        end loop;
        put(147,x"00000000");put(148,x"00000000");restoring<='1';
        clocks(3);read_state(reread);
        for i in 3 to 18 loop
          seed:=std_logic_vector(to_unsigned(16#01230000#+i*257,32));
          assert reread(47+i)=seed report "CP15 field missing from restore/readback" severity failure;
        end loop;
      end if;
      put(0,x"02000000");clocks(3);restoring<='0';reset<='0';
      for i in 1 to 20000 loop
        clocks(1);exit when completed>=8 or (EARLY_CAPTURE and completed>=1);
      end loop;
      assert completed>=1 report "authored program did not start" severity failure;
      -- A request blocked by DMA must not acknowledge. Cancellation must
      -- release normally, including a fetch saved during the DMA hold.
      if not EARLY_CAPTURE then
      dma<='1';req<='1';clocks(80*STEP_PERIOD);
      assert paused='0' report "checkpoint ignored DMA ownership" severity failure;
      req<='0';dma<='0';before:=completed;
      for i in 1 to 20000 loop clocks(1);exit when completed>=before+3;end loop;
      assert completed>=before+3 report "cancel while waiting lost progress" severity failure;
      end if;
      clocks(REQUEST_PHASE);pause_cpu;read_state(saved);
      if THUMB_LOOP then
        assert saved(0)=x"02000040" and saved(17)(5)='1'
          report "Thumb resume PC/mode is incorrect" severity failure;
      else
        assert saved(0)=x"02000020" and saved(17)(5)='0'
          report "ARM resume PC/mode is incorrect" severity failure;
        assert saved(15)=x"0200003C" report "BL link write did not retire before capture" severity failure;
      end if;
      if ARM9 then
      assert saved(65)=x"00000055" and saved(66)=x"00000001"
        report "runtime CP15/Q state was not exported" severity failure;
      end if;
      before:=writes;clocks(100);read_state(reread);
      assert saved=reread and writes=before report "held checkpoint changed" severity failure;
      file_open(capsule,"cpu.state",write_mode);
      for i in saved'range loop hwrite(linebuf,saved(i));writeline(capsule,linebuf);end loop;
      file_close(capsule);
      req<='0';
      for i in 1 to 20000 loop clocks(1);exit when writes>=before+30;end loop;
      assert writes>=before+30 report "cancel did not resume execution" severity failure;
      pause_cpu;
      report "PASS: captured stable CPU state and cancelled hold without lost/duplicate stores";
    elsif OPERATION="restore" then
      restoring<='1';clocks(1);
      file_open(capsule,"cpu.state",read_mode);
      for i in saved'range loop
        readline(capsule,linebuf);hread(linebuf,saved(i));
        if not OMIT_EXT_RESTORE or word_address(i)<128 then
          put(word_address(i),saved(i));
        end if;
      end loop;
      assert endfile(capsule) report "unexpected trailing state data" severity failure;
      file_close(capsule);initial_count<=to_integer(unsigned(saved(2)));
      clocks(4);read_state(reread);
      -- PC export is a retirement latch, not the boot shadow.
      for i in 1 to last_word loop
        assert saved(i)=reread(i)
          report "restored CPU state mismatch at word "&integer'image(word_address(i)) severity failure;
      end loop;
      clocks(2);restoring<='0';reset<='0';
      for i in 1 to 20000 loop clocks(1);exit when writes>=90;end loop;
      assert writes>=90 report "restored program did not progress" severity failure;
      pause_cpu;
      report "PASS: fresh-process CPU restore; 30 complete counter/CPSR/CP15 iterations";
    else assert false report "unknown operation" severity failure;end if;
    stop;wait;
  end process;
  process begin wait for 3 ms;assert false report "test watchdog" severity failure;end process;
end;
