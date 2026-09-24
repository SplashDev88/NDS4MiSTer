-- SPDX-License-Identifier: GPL-3.0-or-later
-- CPU-side ownership of an ordered HPS geometry-result snapshot. A fence is
-- posted through the same lossless GPU source gate as writes. Its posting ACK
-- must NOT retire this read; only a matching complete reply may do so.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity nds_h3d_gx_readback_owner is
   generic (
      -- Nonzero seeds are for bounded exhaustion verification. Production
      -- starts at zero and never resets this sequence on a guest reset.
      INITIAL_REQUEST_SEQUENCE : std_logic_vector(31 downto 0) := x"00000000"
   );
   port (
      clk, reset, service_ready : in std_logic;
      cpu_read : in std_logic;
      address : in std_logic_vector(27 downto 0);
      geometry_write : in std_logic;
      -- Architectural writes, before the posted GPU queue. A downstream tap
      -- can observe BOX_TEST too late for an immediately following status read.
      gx_write : in std_logic := '0';
      gx_address : in std_logic_vector(27 downto 0) := (others=>'0');
      gx_access : in std_logic_vector(1 downto 0) := "10";
      gx_data : in std_logic_vector(31 downto 0) := (others=>'0');
      test_result_bits : out std_logic_vector(1 downto 0) := "00";
      selected, busy, complete : out std_logic;
      read_data : out std_logic_vector(31 downto 0);
      fence_valid : out std_logic;
      request_valid : out std_logic;
      request_ready : in std_logic;
      request_id : out std_logic_vector(31 downto 0);
      response_valid : in std_logic;
      response_id, response_status : in std_logic_vector(31 downto 0);
      cache_index : out std_logic_vector(4 downto 0);
      cache_data : in std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of nds_h3d_gx_readback_owner is
   type state_type is (IDLE, ISSUE, WAIT_REPLY, CACHE_WAIT, CACHE_CAPTURE, EXHAUSTED);
   signal state : state_type := IDLE;
   -- Deliberately retained across guest CPU resets. Resetting this to1 while
   -- an old same-session reply remains in DDR could satisfy the wrong read.
   signal request_sequence : unsigned(31 downto 0) := unsigned(INITIAL_REQUEST_SEQUENCE);
   signal token : std_logic_vector(31 downto 0) := (others=>'0');
   signal cached_valid : std_logic := '0';
   -- A write after a query's fence invalidates that generation even if its
   -- matching response has not arrived yet. A late reply cannot revive it.
   signal request_invalidated : std_logic := '0';
   signal cached_status : std_logic_vector(31 downto 0) := (others=>'0');
   signal index : unsigned(4 downto 0) := (others=>'0');
   signal selected_i : std_logic;
   signal data : std_logic_vector(31 downto 0) := (others=>'0');
   signal test_dirty, test_invalidated, status_read : std_logic := '0';
   signal test_bits : std_logic_vector(1 downto 0) := "00";
   signal packed_commands : std_logic_vector(31 downto 0) := (others=>'0');
   signal packed_count : natural range 0 to 4 := 0;
   signal parameters_left : natural range 0 to 32 := 0;
   signal test_event : std_logic;
   function parameters(command : std_logic_vector(7 downto 0)) return natural is
   begin
      case to_integer(unsigned(command)) is
         when 16#16# | 16#18# => return 16;
         when 16#17# | 16#19# => return 12;
         when 16#1a# => return 9;
         when 16#1b# | 16#1c# | 16#70# => return 3;
         when 16#23# | 16#71# => return 2;
         when 16#34# => return 32;
         when 16#10# | 16#12# | 16#13# | 16#14# | 16#20# | 16#21# |
              16#22# | 16#24# | 16#25# | 16#26# | 16#27# | 16#28# |
              16#29# | 16#2a# | 16#2b# | 16#30# | 16#31# | 16#32# |
              16#33# | 16#40# | 16#50# | 16#60# | 16#72# => return 1;
         when others => return 0;
      end case;
   end function;
begin
   selected_i <= '1' when service_ready='1' and
      ((unsigned(address)>=16#640# and unsigned(address)<=16#67c#) or
       (address=x"0000600" and (test_dirty='1' or test_event='1' or
                               (state/=IDLE and status_read='1')))) else '0';
   test_result_bits <= test_bits;
   test_event <= '1' when gx_write='1' and gx_access="10" and gx_address(1 downto 0)="00" and
      ((gx_address=x"00005c0" or gx_address=x"00005c4") or
       (unsigned(gx_address)>=16#400# and unsigned(gx_address)<16#440# and packed_count/=0 and
        (packed_commands(7 downto 0)=x"70" or packed_commands(7 downto 0)=x"71"))) else '0';
   selected <= selected_i;
   busy <= '1' when state/=IDLE else '0';
   request_id <= token;
   request_valid <= '1' when state=ISSUE and service_ready='1' and reset='0' else '0';
   -- One pulse at request acceptance; the existing GPU gate owns any stall.
   fence_valid <= '1' when state=ISSUE and request_ready='1' and
                            service_ready='1' and reset='0' else '0';
   cache_index <= std_logic_vector(index);
   read_data <= data;

   -- Only command boundaries are shadowed, never vertex data or timing.
   -- Skip zero-parameter commands combinationally so this observer cannot
   -- backpressure the posted CPU/DMA stream or lose back-to-back writes.
   process(clk)
      variable commands : std_logic_vector(31 downto 0);
      variable count : natural range 0 to 4;
      variable remaining : natural range 0 to 32;
   begin
      if rising_edge(clk) then
         if reset='1' or service_ready='0' then
            packed_commands<=(others=>'0'); packed_count<=0; parameters_left<=0;
         elsif gx_write='1' and gx_access="10" and gx_address(1 downto 0)="00" and
               unsigned(gx_address)>=16#400# and unsigned(gx_address)<16#440# then
            commands:=packed_commands; count:=packed_count; remaining:=parameters_left;
            if count=0 then
               commands:=gx_data; count:=4; remaining:=0;
            elsif remaining>1 then remaining:=remaining-1;
            else
               commands:=x"00" & commands(31 downto 8); count:=count-1; remaining:=0;
            end if;
            if remaining=0 then
               for i in 0 to 3 loop
                  if count/=0 and parameters(commands(7 downto 0))=0 then
                     commands:=x"00" & commands(31 downto 8); count:=count-1;
                  end if;
               end loop;
               if count/=0 then remaining:=parameters(commands(7 downto 0)); end if;
            end if;
            packed_commands<=commands; packed_count<=count; parameters_left<=remaining;
         end if;
      end if;
   end process;

   process(clk)
   begin
      if rising_edge(clk) then
         complete <= '0';
         if reset='1' or service_ready='0' then
            state<=IDLE;
            cached_valid<='0';
            request_invalidated<='0';
            data<=(others=>'0');
            test_dirty<='0'; test_invalidated<='0'; status_read<='0'; test_bits<="00";
         else
            case state is
               when IDLE =>
                  if cpu_read='1' and selected_i='1' then
                     status_read<='0'; test_invalidated<='0';
                     if address=x"0000600" then
                        status_read<='1'; index<=to_unsigned(4,5);
                     else index<=to_unsigned(5,5)+resize(unsigned(address(5 downto 2)),5);
                     end if;
                     if address/=x"0000600" and cached_valid='1' and geometry_write='0' and
                        (cached_status and x"08000001")=x"00000000" then
                        state<=CACHE_WAIT;
                     elsif request_sequence/=x"ffffffff" then
                        request_sequence<=request_sequence+1;
                        token<=std_logic_vector(request_sequence+1);
                        request_invalidated<='0';
                        state<=ISSUE;
                     else
                        -- Fail closed rather than reuse a live token on wrap.
                        state<=EXHAUSTED;
                     end if;
                  end if;
               when ISSUE =>
                  if request_ready='1' then state<=WAIT_REPLY; end if;
               when WAIT_REPLY =>
                  if response_valid='1' and response_id=token then
                     cached_status<=response_status;
                     cached_valid<=not request_invalidated;
                     if status_read='1' then
                        test_bits<=response_status(1 downto 0);
                        test_dirty<=test_invalidated or response_status(0) or response_status(27);
                     end if;
                     state<=CACHE_WAIT;
                  end if;
               when CACHE_WAIT =>
                  -- One source-clock RAM read latency after a new index or
                  -- validated DDR publication, before returning CPU data.
                  state<=CACHE_CAPTURE;
               when CACHE_CAPTURE =>
                  if status_read='1' then data<=cached_status and x"00000003";
                  else data<=cache_data; end if;
                  complete<='1'; state<=IDLE;
               when EXHAUSTED =>
                  -- In particular, do not accept a reply for the preceding
                  -- token when no new request could be issued.
                  null;
            end case;
            if geometry_write='1' then
               cached_valid<='0';
               request_invalidated<='1';
            end if;
            if test_event='1' then test_dirty<='1'; test_invalidated<='1'; end if;
         end if;
      end if;
   end process;
end architecture;
