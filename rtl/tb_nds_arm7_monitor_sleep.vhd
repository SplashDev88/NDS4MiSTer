-- SPDX-License-Identifier: GPL-3.0-or-later
-- Authored fixture; no private firmware/BIOS bytes. Actual product ARM7,
-- membus7 and syscnt reproduce the native masked HALTCNT path. A synchronous
-- synthetic BIOS supplies the bus timing; distinct weighted additions after
-- HALT prove no operation was skipped/repeated before BX LR. IRQ stays pending
-- but masked, as in the native BIOS halt routine. DMA_PAUSE drives the CPU's
-- pause/request-save path; no external DMA payload is injected.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use std.textio.all;
use work.pProc_bus_gba.all;
entity tb_nds_arm7_monitor_sleep is
  generic(THUMB:boolean:=false; RETURN_THUMB:boolean:=THUMB;
          HALT_NOPS:natural:=2; COUNT_NOPS:boolean:=true;
          DMA_PAUSE:boolean:=false; WAKE_TICKS:natural:=50;
          MASK_IRQ:boolean:=true; OPERATION:string:="capture";
          MUTATE_PREFETCH:boolean:=false; CORRUPT_WORD:integer:=-1;
          EXPECT_REJECT:boolean:=false; WAKE_PHASE:natural:=0);

end;
architecture sim of tb_nds_arm7_monitor_sleep is
  signal clk:std_logic:='0'; signal reset:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc,regval:std_logic_vector(31 downto 0);
  signal ena,rnw,code,done,halt,irq,unhalt,newhalt,error_cpu:std_logic:='0';
  signal acc:std_logic_vector(1 downto 0);
  signal finished,escaped,irq_seen:boolean:=false;
  signal tick:natural:=0;
  signal checkpoint_req,checkpoint_paused,checkpoint_restore,cpu_idle:std_logic:='0';
  signal monitor_active,monitor_paused,monitor_error:std_logic;
  signal ssout:std_logic_vector(31 downto 0);signal ssdone:std_logic;
  type checkpoint_words is array(0 to 58) of std_logic_vector(31 downto 0);
  signal ha:unsigned(5 downto 0):=(others=>'0');
  signal hdin,hdout:std_logic_vector(31 downto 0):=(others=>'0');
  signal hw,cont,release_run,ready:std_logic:='0';
  signal changed_memory:boolean:=false;
  signal io7:proc_bus_gb_type;
  signal bioaddr:unsigned(13 downto 2);
  signal biodata,ioread,lastread:std_logic_vector(31 downto 0);
  signal iodone:std_logic;
  signal rawhalt:std_logic;
  signal busdin:std_logic_vector(31 downto 0); signal busdone,dma:std_logic;
  function thumb_ins(v:natural) return std_logic_vector is
  begin
    if v=16#180# then return x"3401"; end if;
    if v=16#182# then return x"6404"; end if;
    if v=16#300# then return x"7041"; end if;
    if v>=16#302# and v<16#302#+2*HALT_NOPS then
      if COUNT_NOPS then return std_logic_vector(to_unsigned(16#3400#+2**((v-16#302#)/2),16)); else return x"46C0"; end if;
    end if;
    if v=16#302#+2*HALT_NOPS then return x"4770"; end if;
    return x"E7FE";
  end;

  impure function instruction(a:std_logic_vector(31 downto 0)) return std_logic_vector is
    variable v:natural;
  begin
    if unsigned(a)>4095 then return x"EAFFFFFE"; end if;
    v:=to_integer(unsigned(a));
    if changed_memory and v=16#304# and not THUMB then return x"E2844080";end if;
    if changed_memory and v=16#300# and THUMB then return x"34807041";end if;
    if (RETURN_THUMB and v>=16#180# and v<16#190#) or (THUMB and v>=16#300# and v<16#340#) then
      return thumb_ins(v+2)&thumb_ins(v);
    end if;
    case v is
      when 0 => return x"EA00003E"; -- branch 0x100
      when 16#18# => return x"EA000078"; -- branch IRQ handler 0x200
      when 16#100# =>
        if MASK_IRQ then return x"E321F09F"; else return x"E321F01F"; end if;
      when 16#104# => return x"E3A00301"; -- r0=04000000
      when 16#108# => return x"E2800C03"; -- r0+=300
      when 16#10C# => return x"E3A01080"; -- r1=80
      when 16#110# => return x"E3A04000"; -- r4=0
      when 16#114# => return x"E3A05000"; -- r5=0
      when 16#118# => return x"E3A0EC02"; -- r14=200, replaced next
      when 16#11C# => if RETURN_THUMB then return x"E24EE07F"; else return x"E24EE080"; end if; -- r14=180
      when 16#120# => if THUMB then return x"E3A06C03"; else return x"EA000076"; end if;
      when 16#124# => return x"E2866001";
      when 16#128# => return x"E12FFF16"; -- branch300 (no link)
      when 16#180# => return x"E2844001"; -- first returned operation increments r4
      when 16#184# => return x"E5804100"; -- publish r4 ->04000400
      when 16#188# => return x"EAFFFFFE";
      when 16#200# => return x"E2855001"; -- IRQ count in r5
      when 16#204# => return x"E25EF004"; -- architectural IRQ return
      when 16#300# => return x"E5C01001"; -- HALTCNT byte write
      when others =>
        if v>=16#304# and v<16#304#+4*HALT_NOPS then if COUNT_NOPS then return std_logic_vector(unsigned'(x"E2844000")+2**((v-16#304#)/4)); else return x"E1A00000"; end if; end if;
        if v=16#304#+4*HALT_NOPS then return x"E12FFF1E"; end if;
        return x"EAFFFFFE"; -- fall-through sentinel, no unknown opcodes
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  -- Production CPU ce=1, real membus/syscnt timing, one-clock BIOS data.
  newhalt<=rawhalt;
  dma<='1' when DMA_PAUSE and ((tick mod 13)<5) else '0';
  din<=busdin; done<=busdone;
  dut:entity work.nds_arm7_monitor_probe generic map(SLEEP_ENABLED=>true)
    port map(clk=>clk,ce=>'1',reset=>reset,preset=>ss,addr=>addr,rnw=>rnw,ena=>ena,seq=>open,
      code=>code,acc=>acc,dout=>dout,din=>din,bus_done=>done,dma=>dma,
      irq=>irq,new_halt=>newhalt,unhalt=>unhalt,idle=>cpu_idle,halted=>halt,lastread=>lastread,
      cpu_error=>error_cpu,dbg_pc=>pc,dbg_regsel=>to_unsigned(14,5),dbg_regval=>regval,
      request=>checkpoint_req,continue_run=>cont,restore=>checkpoint_restore,
      active=>monitor_active,paused=>monitor_paused,error=>monitor_error,
      host_addr=>ha,host_write=>hw,host_din=>hdin,host_dout=>hdout,release_run=>release_run,ready=>ready);
  mb:entity work.nds_membus7 port map(
    clk=>clk,reset=>reset,cpu_adr=>addr,cpu_rnw=>rnw,cpu_ena=>ena,cpu_acc=>acc,
    cpu_dout=>dout,cpu_lowbits=>"00",cpu_lastread=>lastread,cpu_din=>busdin,cpu_done=>busdone,
    bios_addr=>bioaddr,bios_data=>biodata,
    w7p_addr=>open,w7p_we=>open,w7p_be=>open,w7p_writedata=>open,w7p_readdata=>x"00000000",
    wsh_ena=>open,wsh_rnw=>open,wsh_addr=>open,wsh_be=>open,wsh_din=>open,
    wsh_dout=>x"00000000",wsh_done=>'0',wsh_mapped=>'0',
    vram_ena=>open,vram_rnw=>open,vram_addr=>open,vram_be=>open,vram_din=>open,
    vram_dout=>x"00000000",vram_done=>'0',
    mr_ena=>open,mr_rnw=>open,mr_addr=>open,mr_be=>open,mr_writedata=>open,
    mr_done=>'0',mr_readdata=>x"00000000",io_ce_next=>'1',
    io_bus=>io7,io_wired_out=>ioread,io_wired_done=>iodone);
  sys:entity work.nds_syscnt port map(
    clk=>clk,reset=>reset,cold_boot=>'1',bus9=>ss,wired_out9=>open,wired_done9=>open,
    bus7=>io7,wired_out7=>ioread,wired_done7=>iodone,preset_direct=>'0',
    wramcnt=>open,vramcnt=>open,pow_2da=>open,pow_2db=>open,pow_swap=>open,
    exmem_gba7=>open,exmem_card7=>open,exmem_prio7=>open,halt7=>rawhalt);
  process(clk)
  begin
    if rising_edge(clk) then
      biodata<=instruction(x"0000" & "00" & std_logic_vector(bioaddr) & "00");
      tick<=tick+1;
      if reset='0' then
        assert monitor_error='0' or EXPECT_REJECT report "sleep monitor error" severity failure;
        assert monitor_active='0' or ena='0' report "sleep monitor leaked guest access" severity failure;
        if io7.ena='1' and io7.rnw='0' and (io7.Adr=x"0000400" or io7.Adr=x"0000340") then
          assert (COUNT_NOPS and unsigned(io7.Din)=2**HALT_NOPS) or (not COUNT_NOPS and io7.Din=x"00000001") report "Post-halt operation skipped/repeated" severity failure;
          finished<=true;
        end if;
        if ena='1' and code='1' and addr=x"00000018" then irq_seen<=true; end if;
        if (not THUMB and pc=std_logic_vector(to_unsigned(16#310#+4*HALT_NOPS,32))) or
           (THUMB and pc=std_logic_vector(to_unsigned(16#308#+2*HALT_NOPS,32))) then escaped<=true; end if;
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
    begin for i in v'range loop ha<=to_unsigned(i,6);clocks(2);v(i):=hdout;end loop;end;
    procedure await_ready is
    begin
      for i in 1 to 50000 loop clocks(1);exit when ready='1' or monitor_error='1';end loop;
      if EXPECT_REJECT then
        assert monitor_error='1' and ready='0' and monitor_active='1' report "bad sleep image was accepted" severity failure;
        clocks(100);assert ena='0' and not finished report "bad sleep image reached guest" severity failure;
        report "PASS: invalid sleep pipeline rejected";stop;wait;
      end if;
      assert ready='1' and halt='1' and monitor_paused='1' and monitor_active='1'
        report "restored HALT pipeline missing at return hold" severity failure;
      if WAKE_PHASE=2 then irq<='1';unhalt<='1';end if;
      cont<='1';clocks(100);cont<='0';
      assert ready='1' and halt='1' and ena='0' and not finished
        report "sleep context escaped before common release" severity failure;
      release_run<='1';clocks(1);release_run<='0';clocks(2);
      assert monitor_active='0' and (halt='1' or WAKE_PHASE/=0) report "HALT lost on common release" severity failure;
    end;
  begin
    wait for 50 ns;wait until falling_edge(clk);
    ss.rst<='1';clocks(3);ss.rst<='0';clocks(2);
    if OPERATION="restore" then
      checkpoint_restore<='1';clocks(2);file_open(state_file,"arm7-monitor-sleep.state",read_mode);
      for i in saved'range loop
        readline(state_file,linebuf);hread(linebuf,saved(i));
        if i=CORRUPT_WORD then
          if EXPECT_REJECT and i=45 then saved(i):=x"00000002";
          elsif EXPECT_REJECT and i=49 then saved(i)(4 downto 0):="11111";
          else saved(i):=saved(i) xor x"00000080";end if;
        end if;
        ha<=to_unsigned(i,6);hdin<=saved(i);hw<='1';clocks(1);
      end loop;hw<='0';file_close(state_file);clocks(4);
      changed_memory<=MUTATE_PREFETCH;reset<='0';clocks(1);checkpoint_restore<='0';
      if WAKE_PHASE=1 then irq<='1';unhalt<='1';end if;
      await_ready;
    else
      reset<='0';
      wait until halt='1' for 100 us;assert halt='1' report "Did not reach HALTCNT halt" severity failure;
      clocks(WAKE_TICKS);checkpoint_req<='1';
      for i in 1 to 50000 loop clocks(1);exit when monitor_paused='1';end loop;
      assert monitor_paused='1' and ready='0' and cpu_idle='1' report "HALT monitor capture timed out" severity failure;
      read_state(saved);clocks(100);read_state(reread);
      assert saved=reread and saved(45)=x"00000001" report "HALT image missing or unstable" severity failure;
      file_open(state_file,"arm7-monitor-sleep.state",write_mode);
      for i in saved'range loop hwrite(linebuf,saved(i));writeline(state_file,linebuf);end loop;file_close(state_file);
      changed_memory<=MUTATE_PREFETCH;checkpoint_req<='0';cont<='1';clocks(1);cont<='0';
      if WAKE_PHASE=1 then irq<='1';unhalt<='1';end if;
      await_ready;
    end if;
    irq<='1'; unhalt<='1';
    if halt/='0' then wait until halt='0' for 100 us;end if;assert halt='0' report "restored CPU did not wake" severity failure; wait until falling_edge(clk); unhalt<='0';
    if not MASK_IRQ then
      if not irq_seen then wait until irq_seen for 100 us;end if;
      assert irq_seen report "Wake IRQ was not taken" severity failure;
      irq<='0';
    end if;
    wait until finished or escaped for 100 us;
    report "WAKE pc="&to_hstring(pc)&" lr="&to_hstring(regval)&" irq_seen="&boolean'image(irq_seen);
    assert finished report "HALT wake failed return / skipped BX LR" severity failure;
    assert irq_seen = (not MASK_IRQ) report "IRQ mask behavior mismatch" severity failure;
    report "PASS: CPU-assisted HALT capture/restore preserves native wake and prefetched operations";
    stop; wait;
  end process;
  process begin wait for 10 ms;assert false report "HALT monitor watchdog" severity failure;end process;
end;
