library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all;     

use work.pProc_bus_gba.all;
use work.pReg_gba_timer.all;
use work.pReg_savestates.all;

entity gba_timer is
   generic
   (
      is_simu : std_logic;
      -- See the iSAVESTATE_TIMER comment below: '1' drops the savestate
      -- registers this core never writes, '0' builds them.
      SS_PRESET_ONLY : std_logic := '1';
      EXPERIMENTAL_CHECKPOINT : boolean := false
   );
   port 
   (
      clk               : in    std_logic;  
      ce                : in    std_logic;
      reset             : in    std_logic;
                        
      savestate_bus     : in    proc_bus_gb_type;
      ss_wired_out      : out   std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      ss_wired_done     : out   std_logic;
      loading_savestate : in    std_logic;
      
      gb_bus            : in    proc_bus_gb_type;
      wired_out         : out   std_logic_vector(proc_buswidth-1 downto 0) := (others => '0');
      wired_done        : out   std_logic;
      
      IRP_Timer         : out   std_logic_vector(3 downto 0);
                        
      timer0_tick       : out   std_logic;
      timer1_tick       : out   std_logic;
                        
      debugout0         : out   unsigned(15 downto 0);
      debugout1         : out   unsigned(15 downto 0);
      debugout2         : out   unsigned(15 downto 0);
      debugout3         : out   unsigned(15 downto 0);
      checkpoint_stop   : in std_logic := '0';
      checkpoint_stopped : out std_logic := '0';
      -- Thirteen-word component image: prescaler then three words per timer.
      checkpoint_address : in unsigned(3 downto 0) := (others => '0');
      checkpoint_data : out std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_valid : out std_logic := '0';
      checkpoint_restore : in std_logic := '0';
      checkpoint_write : in std_logic := '0';
      checkpoint_write_data : in std_logic_vector(31 downto 0) := (others => '0');
      checkpoint_restore_ready : out std_logic := '0';
      checkpoint_restore_error : out std_logic := '0'
   );
end entity;

architecture arch of gba_timer is
   signal stop_count : std_logic;
   signal stop_seen : std_logic := '0';
   signal restore_active, restore_write_valid : std_logic;
   signal restore_loaded : std_logic_vector(12 downto 0) := (others => '0');
   signal restore_error : std_logic := '0';
   type checkpoint_addresses is array(0 to 3) of unsigned(1 downto 0);
   type checkpoint_words is array(0 to 3) of std_logic_vector(31 downto 0);
   signal module_address : checkpoint_addresses := (others => (others => '0'));
   signal module_data : checkpoint_words;
   signal module_write, module_quiet : std_logic_vector(0 to 3);
 
   type t_reg_wired_or is array(0 to 3) of std_logic_vector(31 downto 0);
   signal reg_wired_or    : t_reg_wired_or;   
   signal reg_wired_done  : unsigned(0 to 3);
 
   signal timerticks : std_logic_vector(3 downto 0);
   
   signal prescaleCounter : unsigned(9 downto 0) := (others => '0');
 
   -- savestates
   signal SAVESTATE_TIMER      : std_logic_vector(29 downto 0);
    
   type t_ss_wired_or is array(0 to 3) of std_logic_vector(31 downto 0);
   signal save_wired_or        : t_ss_wired_or;   
   signal save_wired_done      : unsigned(0 to 3);
 
begin
   stop_count <= checkpoint_stop when EXPERIMENTAL_CHECKPOINT else '0';
   process(clk) begin
      if rising_edge(clk) then
         if reset = '1' then stop_seen <= '0';
         else stop_seen <= stop_count; end if;
      end if;
   end process;
   checkpoint_stopped <= '1' when EXPERIMENTAL_CHECKPOINT and
      reset = '0' and stop_count = '1' and stop_seen = '1' and
      gb_bus.ena = '0' and IRP_Timer = "0000" and timerticks = "0000" else '0';

   restore_active <= '1' when EXPERIMENTAL_CHECKPOINT and reset = '1' and checkpoint_restore = '1' else '0';
   process(all)
      variable a : natural range 0 to 15;
      variable allowed : std_logic_vector(31 downto 0);
   begin
      a := to_integer(checkpoint_address);
      allowed := (others => '0');
      if a = 0 then allowed := x"000003FF";
      else
         for timer in 0 to 3 loop
            if a = 1+timer*3 then allowed := x"00C7FFFF"; end if;
            if a = 2+timer*3 then allowed := x"FFFFFFFF"; end if;
            if a = 3+timer*3 then allowed := x"00000003"; end if;
         end loop;
      end if;
      restore_write_valid <= '0';
      if restore_active = '1' and restore_error = '0' and checkpoint_write = '1' and
         a < 13 and (checkpoint_write_data and not allowed) = x"00000000" then
         restore_write_valid <= '1';
      end if;
      module_address <= (others => (others => '0')); module_write <= (others => '0');
      for timer in 0 to 3 loop
         if a >= 1+timer*3 and a <= 3+timer*3 then
            module_address(timer) <= to_unsigned(a-1-timer*3,2);
            module_write(timer) <= restore_write_valid;
         end if;
      end loop;
      checkpoint_data <= (others => '0'); checkpoint_valid <= '0';
      if EXPERIMENTAL_CHECKPOINT and a < 13 and
         ((checkpoint_stopped = '1' and checkpoint_restore = '0' and
           module_quiet = "1111" and gb_bus.rst = '0') or checkpoint_restore_ready = '1') then
         checkpoint_valid <= '1';
         if a = 0 then checkpoint_data <= (31 downto 10 => '0') & std_logic_vector(prescaleCounter);
         else
            for timer in 0 to 3 loop
               if a >= 1+timer*3 and a <= 3+timer*3 then checkpoint_data <= module_data(timer); end if;
            end loop;
         end if;
      end if;
   end process;
   process(clk) begin
      if rising_edge(clk) then
         if not EXPERIMENTAL_CHECKPOINT or checkpoint_restore = '0' then
            restore_loaded <= (others => '0'); restore_error <= '0';
         elsif reset = '0' then restore_error <= '1';
         elsif checkpoint_write = '1' then
            if restore_write_valid = '1' then restore_loaded(to_integer(checkpoint_address)) <= '1';
            else restore_error <= '1'; end if;
         end if;
      end if;
   end process;
   checkpoint_restore_error <= restore_error when EXPERIMENTAL_CHECKPOINT else '0';
   checkpoint_restore_ready <= '1' when restore_active = '1' and restore_loaded = (12 downto 0 => '1') and
      restore_error = '0' and checkpoint_write = '0' and module_quiet = "1111" else '0';

   -- REG_SAVESTATE_TIMER is at address 62 (size 4, so 62-65). nds_top's boot
   -- preset only ever writes savestate addresses 0, 13, 14, 15, 24, 34 and 37
   -- (preset_adr in nds_top.vhd) and never reads the bus back, so this
   -- register can only ever hold its startVal of 0 - it exists purely so
   -- Quartus can build 30 flops that never change. Tying it to 0 is bit-exact:
   -- the reset load below already lands 0 in prescaleCounter either way.
   -- Set SS_PRESET_ONLY = '0' to get the register back with savestates.
   gss_full : if SS_PRESET_ONLY = '0' generate
      iSAVESTATE_TIMER : entity work.eProcReg_gba generic map (REG_SAVESTATE_TIMER, 0) port map (clk, savestate_bus, open, open, 30x"0", SAVESTATE_TIMER);
   end generate;
   gss_preset : if SS_PRESET_ONLY = '1' generate
      SAVESTATE_TIMER <= (others => '0');
   end generate;

   process (reg_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := reg_wired_or(0);
      for i in 1 to (reg_wired_or'length - 1) loop
         wired_or := wired_or or reg_wired_or(i);
      end loop;
      wired_out <= wired_or;
   end process;
   wired_done <= '0' when (reg_wired_done = 0) else '1';
   
   process (save_wired_or)
      variable wired_or : std_logic_vector(31 downto 0);
   begin
      wired_or := save_wired_or(0);
      for i in 1 to (save_wired_or'length - 1) loop
         wired_or := wired_or or save_wired_or(i);
      end loop;
      ss_wired_out <= wired_or;
   end process;
   ss_wired_done <= '0' when (save_wired_done = 0) else '1';

   timer0_tick <= timerticks(0);
   timer1_tick <= timerticks(1);


   process (clk)
   begin
      if rising_edge(clk) then
         if (reset = '1') then
            if restore_active = '1' then
               if restore_write_valid = '1' and checkpoint_address = 0 then
                  prescaleCounter <= unsigned(checkpoint_write_data(9 downto 0));
               end if;
            else
               prescaleCounter <= unsigned(SAVESTATE_TIMER(28 downto 19));
            end if;
         elsif (ce = '1' and stop_count = '0') then
            prescaleCounter <= prescaleCounter + 1;
         end if;
      end if;
   end process;

   igba_timer_module0 : entity work.gba_timer_module
   generic map
   (
      is_simu                => is_simu,
      index                  => 0, 
      Reg_L                  => TM0CNT_L,
      Reg_H_Prescaler        => TM0CNT_H_Prescaler       ,
      Reg_H_Count_up         => TM0CNT_H_Count_up        ,
      Reg_H_Timer_IRQ_Enable => TM0CNT_H_Timer_IRQ_Enable,
      Reg_H_Timer_Start_Stop => TM0CNT_H_Timer_Start_Stop,
      EXPERIMENTAL_CHECKPOINT => EXPERIMENTAL_CHECKPOINT
   )                                  
   port map
   (
      clk               => clk,   
      ce                => ce,  
      reset             => reset,
                        
      savestate_bus     => savestate_bus,
      ss_wired_out      => save_wired_or(0),
      ss_wired_done     => save_wired_done(0),
      loading_savestate => loading_savestate,
      
      gb_bus            => gb_bus,           
      wired_out         => reg_wired_or(0),
      wired_done        => reg_wired_done(0),
                        
      prescaleCounter   => prescaleCounter,
      countup_in        => '0',
                        
      tick              => timerticks(0),
      IRP_Timer         => IRP_Timer(0),
                        
      debugout          => debugout0,
      checkpoint_stop => stop_count,
      checkpoint_restore => restore_active,
      checkpoint_address => module_address(0), checkpoint_data => module_data(0),
      checkpoint_write => module_write(0), checkpoint_write_data => checkpoint_write_data,
      checkpoint_quiet => module_quiet(0)
   );
   
   igba_timer_module1 : entity work.gba_timer_module
   generic map
   (
      is_simu                => is_simu,
      index                  => 1, 
      Reg_L                  => TM1CNT_L,
      Reg_H_Prescaler        => TM1CNT_H_Prescaler       ,
      Reg_H_Count_up         => TM1CNT_H_Count_up        ,
      Reg_H_Timer_IRQ_Enable => TM1CNT_H_Timer_IRQ_Enable,
      Reg_H_Timer_Start_Stop => TM1CNT_H_Timer_Start_Stop,
      EXPERIMENTAL_CHECKPOINT => EXPERIMENTAL_CHECKPOINT
   )                                  
   port map
   (
      clk               => clk,   
      ce                => ce,
      reset             => reset,
                        
      savestate_bus     => savestate_bus,
      ss_wired_out      => save_wired_or(1),
      ss_wired_done     => save_wired_done(1),
      loading_savestate => loading_savestate,
      
      gb_bus            => gb_bus,           
      wired_out         => reg_wired_or(1),
      wired_done        => reg_wired_done(1),
                        
      prescaleCounter   => prescaleCounter,
      countup_in        => timerticks(0),
                        
      tick              => timerticks(1),
      IRP_Timer         => IRP_Timer(1),
                        
      debugout          => debugout1,
      checkpoint_stop => stop_count,
      checkpoint_restore => restore_active,
      checkpoint_address => module_address(1), checkpoint_data => module_data(1),
      checkpoint_write => module_write(1), checkpoint_write_data => checkpoint_write_data,
      checkpoint_quiet => module_quiet(1)
   );
   
   igba_timer_module2 : entity work.gba_timer_module
   generic map
   (
      is_simu                => is_simu,
      index                  => 2, 
      Reg_L                  => TM2CNT_L,
      Reg_H_Prescaler        => TM2CNT_H_Prescaler       ,
      Reg_H_Count_up         => TM2CNT_H_Count_up        ,
      Reg_H_Timer_IRQ_Enable => TM2CNT_H_Timer_IRQ_Enable,
      Reg_H_Timer_Start_Stop => TM2CNT_H_Timer_Start_Stop,
      EXPERIMENTAL_CHECKPOINT => EXPERIMENTAL_CHECKPOINT
   )                                  
   port map
   (
      clk               => clk,
      ce                => ce,  
      reset             => reset,
                        
      savestate_bus     => savestate_bus,
      ss_wired_out      => save_wired_or(2),
      ss_wired_done     => save_wired_done(2),
      loading_savestate => loading_savestate,
      
      gb_bus            => gb_bus,           
      wired_out         => reg_wired_or(2),
      wired_done        => reg_wired_done(2),

      prescaleCounter   => prescaleCounter,
      countup_in        => timerticks(1),
                        
      tick              => timerticks(2),
      IRP_Timer         => IRP_Timer(2),
                        
      debugout          => debugout2,
      checkpoint_stop => stop_count,
      checkpoint_restore => restore_active,
      checkpoint_address => module_address(2), checkpoint_data => module_data(2),
      checkpoint_write => module_write(2), checkpoint_write_data => checkpoint_write_data,
      checkpoint_quiet => module_quiet(2)
   );
   
   igba_timer_module3 : entity work.gba_timer_module
   generic map
   (
      is_simu                => is_simu,
      index                  => 3, 
      Reg_L                  => TM3CNT_L,
      Reg_H_Prescaler        => TM3CNT_H_Prescaler       ,
      Reg_H_Count_up         => TM3CNT_H_Count_up        ,
      Reg_H_Timer_IRQ_Enable => TM3CNT_H_Timer_IRQ_Enable,
      Reg_H_Timer_Start_Stop => TM3CNT_H_Timer_Start_Stop,
      EXPERIMENTAL_CHECKPOINT => EXPERIMENTAL_CHECKPOINT
   )                                  
   port map
   (
      clk               => clk,   
      ce                => ce, 
      reset             => reset,
                        
      savestate_bus     => savestate_bus,
      ss_wired_out      => save_wired_or(3),
      ss_wired_done     => save_wired_done(3),
      loading_savestate => loading_savestate,
      
      gb_bus            => gb_bus,           
      wired_out         => reg_wired_or(3),
      wired_done        => reg_wired_done(3),
       
      prescaleCounter   => prescaleCounter,
      countup_in        => timerticks(2),
                        
      tick              => timerticks(3),
      IRP_Timer         => IRP_Timer(3),
                        
      debugout          => debugout3,
      checkpoint_stop => stop_count,
      checkpoint_restore => restore_active,
      checkpoint_address => module_address(3), checkpoint_data => module_data(3),
      checkpoint_write => module_write(3), checkpoint_write_data => checkpoint_write_data,
      checkpoint_quiet => module_quiet(3)
   );
    

end architecture;





