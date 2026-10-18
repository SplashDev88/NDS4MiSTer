-- SPDX-License-Identifier: GPL-3.0-or-later
-- Real production cache/TCM decoder; authored BIOS program. CPU-only reset
-- deliberately retains memory. This proves isolation, NOT cache persistence.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_arm9_monitor_memory is
  generic(SLEEP_MODE:boolean:=false; MEMORY_DELAY:natural:=2;
          ITCM_OVERLAY:boolean:=true; LOSE_CACHE:boolean:=false);
end;
architecture sim of tb_nds_arm9_monitor_memory is
  constant STEP_PERIOD:positive:=1; -- Production ARM9 memory island CE is continuous.
  signal clk:std_logic:='0';signal mem_reset,cpu_reset:std_logic:='1';
  signal ce,cpu_enable:std_logic:='0';signal manual:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal ca,cw,ma,mw,a,wd,rd,lastread:std_logic_vector(31 downto 0):=(others=>'0');
  signal cg,cr,cc,mg,mc,g,r,c,done,mem_idle,op_busy,op_ena:std_logic:='0';
  signal mr:std_logic:='1';
  signal ci,cd,wb,denied,ie,il,de,dl:std_logic;
  signal db:std_logic_vector(31 downto 12);signal ds,its:std_logic_vector(4 downto 0);
  signal m_itcm,m_dtcm,sel_ie,sel_de,sel_il,sel_dl,sel_ci,sel_cd,sel_wb,sel_denied:std_logic:='0';
  signal sel_its,sel_ds:std_logic_vector(4 downto 0);signal sel_db:std_logic_vector(31 downto 12);
  signal op:std_logic_vector(3 downto 0);signal op_addr:std_logic_vector(31 downto 0);
  signal req,cont,restore,release_run,ready,active,paused,err,hw:std_logic:='0';
  signal ha:unsigned(5+boolean'pos(SLEEP_MODE) downto 0):=(others=>'0');signal hdi,hdo:std_logic_vector(31 downto 0):=(others=>'0');
  signal ia,ba:unsigned(14 downto 2);signal da,da_b:unsigned(13 downto 2);
  signal iw,dw:std_logic;signal ibe,dbe:std_logic_vector(3 downto 0);
  signal idata,ddata,iq,dq,bq:std_logic_vector(31 downto 0);
  type itype is array(0 to 8191) of std_logic_vector(31 downto 0);
  type dtype is array(0 to 4095) of std_logic_vector(31 downto 0);
  signal imem:itype:=(others=>x"D0D00000");signal dmem:dtype:=(others=>x"E0E00000");
  signal me,mrn,mp,mdone:std_logic:='0';signal maddr:std_logic_vector(21 downto 2);
  signal mbe:std_logic_vector(3 downto 0);signal mdata,mq,mqhi:std_logic_vector(31 downto 0);
  signal reads,writes,guest_fetches:natural:=0;
  signal change_backing:std_logic:='0';
  type snapshot_type is array(0 to 63+14*boolean'pos(SLEEP_MODE)) of std_logic_vector(31 downto 0);
  function bios(i:natural) return std_logic_vector is
  begin
    case i is
      when 0=>return x"E59F0068"; -- ldr r0, [pc,#104] = dtcm region
      when 1=>return x"EE090F11"; -- mcr p15,0,r0,c9,c1,0
      when 2=>return x"E3A00026"; -- ITCM covers 256MB, including private window
      when 3=>return x"EE090F31";
      when 4=>return x"E59F005C"; -- control: PU/cache/TCM enabled
      when 5=>return x"EE010F10";
      when 6=>return x"E3A00000"; -- deny data stores in every PU region
      when 7=>return x"EE050F50";
      when 8=>return x"EAFFFFFE";
      when 28=>return x"0F00000A";
      when 29=>if ITCM_OVERLAY then return x"0005107D";else return x"0001107D";end if;
      when others=>return x"EAFFFFFE";
    end case;
  end;
begin
  clk<=not clk after 5 ns;
  process begin
    for i in 1 to STEP_PERIOD loop
      wait until falling_edge(clk);
      if i=STEP_PERIOD then ce<=cpu_enable;else ce<='0';end if;
    end loop;
  end process;
  a<=ma when manual='1' else ca;wd<=mw when manual='1' else cw;
  g<=mg when manual='1' else cg;r<=mr when manual='1' else cr;c<=mc when manual='1' else cc;
  sel_ie<=m_itcm when manual='1' else ie;sel_de<=m_dtcm when manual='1' else de;
  sel_il<='0' when manual='1' else il;sel_dl<='0' when manual='1' else dl;
  sel_its<="00110" when manual='1' else its; -- 32KB manual ITCM window
  sel_ds<="00101" when manual='1' else ds;
  sel_db<=x"0F000" when manual='1' else db;
  sel_ci<='1' when manual='1' else ci;sel_cd<='1' when manual='1' else cd;
  sel_wb<='0' when manual='1' else wb;sel_denied<='0' when manual='1' else denied;
  cpu:entity work.nds_arm9_monitor_probe generic map(SLEEP_ENABLED=>SLEEP_MODE)
    port map(clk=>clk,ce=>ce,reset=>cpu_reset,preset=>ss,addr=>ca,rnw=>cr,ena=>cg,seq=>open,
      code=>cc,acc=>open,dout=>cw,din=>rd,bus_done=>done,dma=>'0',irq=>'0',new_halt=>'0',unhalt=>'0',
      idle=>open,halted=>open,request=>req,continue_run=>cont,restore=>restore,
      memory_idle=>mem_idle,cache_op_busy=>op_busy,cache_op_ena=>op_ena,cache_op=>op,cache_op_addr=>op_addr,
      cp15_itcm_ena=>ie,cp15_itcm_load=>il,cp15_itcm_size=>its,
      cp15_dtcm_ena=>de,cp15_dtcm_load=>dl,cp15_dtcm_base=>db,cp15_dtcm_size=>ds,
      bus_cacheable_i=>ci,bus_cacheable_d=>cd,bus_bufferable_d=>wb,bus_wdenied_d=>denied,
      active=>active,paused=>paused,error=>err,host_addr=>ha,host_write=>hw,host_din=>hdi,host_dout=>hdo,
      release_run=>release_run,ready=>ready,lastread=>lastread);
  memory:entity work.nds_membus9 generic map(is_simu=>'1')
    port map(clk=>clk,reset=>mem_reset,checkpoint_idle=>mem_idle,
      itcm_ena=>sel_ie,itcm_load=>sel_il,itcm_size=>sel_its,
      dtcm_ena=>sel_de,dtcm_load=>sel_dl,dtcm_base=>sel_db,dtcm_size=>sel_ds,
      bus_cacheable_i=>sel_ci,bus_cacheable_d=>sel_cd,bus_bufferable_d=>sel_wb,bus_wdenied_d=>sel_denied,
      cache_op_ena=>op_ena,cache_op=>op,cache_op_addr=>op_addr,cache_op_busy=>op_busy,
      cpu_adr=>a,cpu_rnw=>r,cpu_ena=>g,cpu_code=>c,cpu_acc=>ACCESS_32BIT,cpu_dout=>wd,
      cpu_lowbits=>a(1 downto 0),cpu_lastread=>lastread,cpu_din=>rd,cpu_done=>done,
      itcm_addr=>ia,itcm_we=>iw,itcm_be=>ibe,itcm_writedata=>idata,itcm_readdata=>iq,
      dtcm_addr=>da,dtcm_readdata=>dq,dtcm_addr_b=>da_b,dtcm_we_b=>dw,dtcm_be_b=>dbe,dtcm_writedata_b=>ddata,
      brom_addr=>ba,brom_data=>bq,
      wsh_ena=>open,wsh_rnw=>open,wsh_addr=>open,wsh_be=>open,wsh_din=>open,
      wsh_dout=>x"00000000",wsh_done=>'0',wsh_mapped=>'0',
      vram_ena=>open,vram_rnw=>open,vram_addr=>open,vram_be=>open,vram_din=>open,
      vram_dout=>x"00000000",vram_done=>'0',
      pal_we=>open,pal_addr=>open,pal_din=>open,pal_be=>open,pal_readdata=>x"00000000",
      oam_we=>open,oam_addr=>open,oam_din=>open,oam_be=>open,
      mr_ena=>me,mr_rnw=>mrn,mr_addr=>maddr,mr_be=>mbe,mr_writedata=>mdata,
      mr_done=>mdone,mr_readdata=>mq,mr_pair=>mp,mr_readdata_hi=>mqhi,
      io_ce_next=>'1',io_bus=>open,io_wired_out=>x"00000000",io_wired_done=>'0');
  process(clk)
    variable remaining:integer:=-1;variable index:natural:=0;
  begin
    if rising_edge(clk) then
      iq<=imem(to_integer(ia));dq<=dmem(to_integer(da));bq<=bios(to_integer(ba));
      if iw='1' then
        for lane in 0 to 3 loop
          if ibe(lane)='1' then imem(to_integer(ia))(lane*8+7 downto lane*8)<=idata(lane*8+7 downto lane*8);end if;
        end loop;
      end if;
      if dw='1' then
        for lane in 0 to 3 loop
          if dbe(lane)='1' then dmem(to_integer(da_b))(lane*8+7 downto lane*8)<=ddata(lane*8+7 downto lane*8);end if;
        end loop;
      end if;
      if manual='0' and cg='1' then
        assert ca(31 downto 16)=x"FFFF" and cr='1' report "unexpected guest memory access" severity failure;
        guest_fetches<=guest_fetches+1;
      end if;
      if active='1' and mem_reset='0' then
        assert cg='0' and me='0' and iw='0' and dw='0' and op_ena='0'
          report "maintenance leaked into guest cache/TCM" severity failure;
      end if;
      assert err='0' report "monitor memory protocol error" severity failure;
      mdone<='0';
      if me='1' then
        assert remaining=-1 report "overlapping memory request" severity failure;
        remaining:=MEMORY_DELAY+1;index:=to_integer(unsigned(maddr));
        if mrn='1' then reads<=reads+1;else writes<=writes+1;end if;
      elsif remaining>=0 then
        if remaining=0 then
          if index>=2048 and change_backing='1' then mq<=x"11223344";mqhi<=x"11223344";
          else mq<=x"12345678";mqhi<=x"12345678";end if;
          mdone<='1';
        end if;
        remaining:=remaining-1;
      end if;
    end if;
  end process;
  process
    variable image:snapshot_type;variable count_before:natural;
    procedure clocks(n:natural) is
    begin for i in 1 to n loop wait until falling_edge(clk);end loop;end;
    procedure idle_memory is
    begin
      for i in 1 to 10000 loop clocks(1);exit when mem_idle='1';end loop;
      assert mem_idle='1' report "memory did not drain" severity failure;
    end;
    procedure transfer(address,value:std_logic_vector(31 downto 0);is_read,instruction:std_logic) is
    begin
      ma<=address;mw<=value;mr<=is_read;mc<=instruction;mg<='1';clocks(1);mg<='0';
      for i in 1 to 10000 loop exit when done='1';clocks(1);end loop;
      assert done='1' report "manual memory request timeout" severity failure;
      if is_read='1' then
        assert value=rd report "retained memory mismatch at "&to_hstring(address)&" got "&to_hstring(rd) severity failure;
      end if;
      idle_memory;
    end;
    procedure verify_memory is
    begin
      count_before:=reads;
      transfer(x"02001000",x"DEADBEEF",'1','0');
      transfer(x"02002000",x"12345678",'1','1');
      assert reads=count_before and writes=0 report "dirty D/I cache was lost or written back" severity failure;
      m_itcm<='1';transfer(x"00000100",x"13579BDF",'1','0');m_itcm<='0';
      m_dtcm<='1';transfer(x"0F000100",x"2468ACE0",'1','0');m_dtcm<='0';
    end;
    procedure await_ready is
    begin
      for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when ready='1';end loop;
      assert ready='1' and active='1' and paused='1' report "memory fixture return timed out" severity failure;
      clocks(100*STEP_PERIOD);
    end;
  begin
    clocks(5);mem_reset<='0';clocks(5);
    transfer(x"02001000",x"12345678",'1','0');
    transfer(x"02001000",x"DEADBEEF",'0','0');
    transfer(x"02002000",x"12345678",'1','1');change_backing<='1';
    m_itcm<='1';transfer(x"00000100",x"13579BDF",'0','0');m_itcm<='0';
    m_dtcm<='1';transfer(x"0F000100",x"2468ACE0",'0','0');m_dtcm<='0';
    verify_memory;
    ss.rst<='1';clocks(4);ss.rst<='0';clocks(2);
    ss.Adr<=(others=>'0');ss.Din<=x"FFFF0000";ss.rnw<='0';ss.ena<='1';clocks(1);ss.ena<='0';clocks(4);
    manual<='0';cpu_reset<='0';cpu_enable<='1';
    for i in 1 to 10000*STEP_PERIOD loop clocks(1);exit when guest_fetches>=40;end loop;
    assert guest_fetches>=40 and de='1' and its="10011" and denied='1'
      report "guest CP15 overlay/permission setup failed" severity failure;
    if ITCM_OVERLAY then assert ie='1' report "missing ITCM private overlay" severity failure;end if;
    req<='1';
    for i in 1 to 50000*STEP_PERIOD loop clocks(1);exit when paused='1';end loop;
    assert paused='1' report "memory fixture capture timed out" severity failure;
    for i in image'range loop ha<=to_unsigned(i,ha'length);clocks(2);image(i):=hdo;end loop;
    req<='0';cont<='1';clocks(1);cont<='0';await_ready;
    release_run<='1';clocks(1);release_run<='0';
    clocks(100*STEP_PERIOD);cpu_enable<='0';clocks(STEP_PERIOD+2);idle_memory;manual<='1';clocks(2);
    if LOSE_CACHE then mem_reset<='1';clocks(4);mem_reset<='0';clocks(4);end if;
    verify_memory;
    -- CPU-only cold instance with unchanged memory owners. No memory dump or
    -- power-cycle claim: separate memory-state serialization remains required.
    cpu_reset<='1';restore<='1';clocks(4);
    for i in image'range loop ha<=to_unsigned(i,ha'length);hdi<=image(i);hw<='1';clocks(1);end loop;
    hw<='0';clocks(4);manual<='0';cpu_reset<='0';cpu_enable<='1';clocks(1);restore<='0';await_ready;
    release_run<='1';clocks(1);release_run<='0';clocks(100*STEP_PERIOD);
    cpu_enable<='0';clocks(STEP_PERIOD+2);idle_memory;manual<='1';clocks(2);verify_memory;
    report "PASS: dirty D-cache, stale I-cache and both TCMs survive monitor and CPU-only restore";
    stop;wait;
  end process;
  process begin wait for 30 ms;assert false report "memory monitor watchdog" severity failure;end process;
end;
