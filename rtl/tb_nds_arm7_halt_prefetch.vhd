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
use work.pProc_bus_gba.all;
entity tb_nds_arm7_halt_prefetch is
  generic(THUMB:boolean:=false; RETURN_THUMB:boolean:=THUMB;
          HALT_NOPS:natural:=2; COUNT_NOPS:boolean:=true;
          DMA_PAUSE:boolean:=false; WAKE_TICKS:natural:=50);
end;
architecture sim of tb_nds_arm7_halt_prefetch is
  signal clk:std_logic:='0'; signal reset:std_logic:='1';
  signal ss:proc_bus_gb_type:=((others=>'0'),(others=>'0'),'0','0',"10","1111",'0');
  signal addr,din,dout,pc,regval:std_logic_vector(31 downto 0);
  signal ena,rnw,code,done,halt,irq,unhalt,newhalt,error_cpu:std_logic:='0';
  signal acc:std_logic_vector(1 downto 0);
  signal finished,escaped,irq_seen:boolean:=false;
  signal tick:natural:=0;
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

  function instruction(a:std_logic_vector(31 downto 0)) return std_logic_vector is
    variable v:natural;
  begin
    if unsigned(a)>4095 then return x"EAFFFFFE"; end if;
    v:=to_integer(unsigned(a));
    if (RETURN_THUMB and v>=16#180# and v<16#190#) or (THUMB and v>=16#300# and v<16#340#) then
      return thumb_ins(v+2)&thumb_ins(v);
    end if;
    case v is
      when 0 => return x"EA00003E"; -- branch 0x100
      when 16#18# => return x"EA000078"; -- branch IRQ handler 0x200
      when 16#100# =>
        return x"E321F09F"; -- native-style masked IRQ, unhalt is independent
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
  dut:entity work.gba_cpu generic map(is_simu=>'0') port map(
    clk=>clk,ce=>'1',reset=>reset,error_cpu=>error_cpu,dbg_pc=>pc,
    dbg_regsel=>to_unsigned(14,5),dbg_regval=>regval,savestate_bus=>ss,
    ss_wired_out=>open,ss_wired_done=>open,
    gb_bus_Adr=>addr,gb_bus_rnw=>rnw,gb_bus_ena=>ena,gb_bus_code=>code,
    gb_bus_seq=>open,gb_bus_acc=>acc,gb_bus_dout=>dout,
    gb_bus_din=>din,gb_bus_done=>done,gb_bus_lock=>open,bus_lowbits=>open,
    dma_on=>dma,done=>open,CPU_bus_idle=>open,PC_in_BIOS=>open,
    cpu_halt=>halt,lastread=>lastread,jump_out=>open,IRQ_in=>irq,
    unhalt=>unhalt,new_halt=>newhalt);
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
  begin
    wait for 50 ns; wait until falling_edge(clk); reset<='0';
    wait until halt='1' for 100 us;
    assert halt='1' report "Did not reach HALTCNT halt" severity failure;
    report "HALTED pc="&to_hstring(pc)&" lr="&to_hstring(regval);
    for i in 1 to WAKE_TICKS loop wait until falling_edge(clk); end loop; irq<='1'; unhalt<='1';
    wait until halt='0'; wait until falling_edge(clk); unhalt<='0';
    wait until finished or escaped for 100 us;
    report "WAKE pc="&to_hstring(pc)&" lr="&to_hstring(regval)&" irq_seen="&boolean'image(irq_seen);
    assert finished report "HALT wake failed return / skipped BX LR" severity failure;
    assert not irq_seen report "IRQ mask behavior mismatch" severity failure;
    report "PASS: HALTCNT wake preserves following operations and BX LR";
    stop; wait;
  end process;
end;
