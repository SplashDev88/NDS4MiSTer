-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sequential use of the monitor's single RAM port while the CPU is stopped.
-- Capture stores fourteen live words; restore presents one synchronous read
-- at a time. End acknowledgements never share an edge with the final transfer.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
entity nds_monitor_pipeline_transfer is
  port(clk,reset,capture,restore:in std_logic;
    busy,ram_write,ram_enable:out std_logic;
    address:out unsigned(3 downto 0);
    cpu_write,captured,loaded:out std_logic);
end;
architecture rtl of nds_monitor_pipeline_transfer is
  type state_type is (IDLE,COPY_SAVE,SAVE_END,SAVE_WAIT,LOAD_ADDR,LOAD_DATA,LOAD_END,LOAD_WAIT);
  signal state:state_type:=IDLE;
  signal index:unsigned(3 downto 0):=(others=>'0');
begin
  address<=index;
  busy<='1' when state=COPY_SAVE or state=LOAD_ADDR or state=LOAD_DATA else '0';
  ram_enable<='1' when state=COPY_SAVE or state=LOAD_ADDR else '0';
  ram_write<='1' when state=COPY_SAVE else '0';
  cpu_write<='1' when state=LOAD_DATA else '0';
  captured<='1' when state=SAVE_END else '0';
  loaded<='1' when state=LOAD_END else '0';
  process(clk) begin
    if rising_edge(clk) then
      if reset='1' then state<=IDLE;index<=(others=>'0');
      else
        case state is
          when IDLE=>
            index<=(others=>'0');
            if capture='1' then state<=COPY_SAVE;elsif restore='1' then state<=LOAD_ADDR;end if;
          when COPY_SAVE=>
            if index=13 then state<=SAVE_END;else index<=index+1;end if;
          when SAVE_END=>state<=SAVE_WAIT;
          when SAVE_WAIT=>if capture='0' then state<=IDLE;end if;
          when LOAD_ADDR=>state<=LOAD_DATA;
          when LOAD_DATA=>
            if index=13 then state<=LOAD_END;else index<=index+1;state<=LOAD_ADDR;end if;
          when LOAD_END=>state<=LOAD_WAIT;
          when LOAD_WAIT=>if restore='0' then state<=IDLE;end if;
        end case;
      end if;
    end if;
  end process;
end;
