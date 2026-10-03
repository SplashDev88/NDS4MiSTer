library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;
entity tb_nds_spi_firmware_backpressure is end entity;
architecture test of tb_nds_spi_firmware_backpressure is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal bus7 : proc_bus_gb_type := (Din=>(others=>'0'),Adr=>x"00001C0",
      rnw=>'1',ena=>'0',acc=>"10",bEna=>"0000",rst=>'0');
   signal q : std_logic_vector(31 downto 0);
   signal req, wr, ack : std_logic := '0';
   signal addr : unsigned(17 downto 2);
   signal lane : unsigned(1 downto 0);
   signal wdata : std_logic_vector(7 downto 0);
   signal data : std_logic_vector(31 downto 0) := x"76543210";
   signal busy : std_logic := '0';
   signal release_cs : std_logic;
   signal releases, clocks, ack_at, reads, writes : natural := 0;
   signal delay_cycles : natural := 1500;
   signal memory_word : std_logic_vector(31 downto 0) := x"76543210";
begin
   clk <= not clk after 5 ns;
   dut : entity work.nds_nitro_spi
   port map(clk=>clk,reset=>reset,bus7=>bus7,wired_out7=>q,
      touch_active=>'0',touch_x=>x"00",touch_y=>x"00",
      fw_req=>req,fw_addr=>addr,fw_wr=>wr,fw_wlane=>lane,fw_wdata=>wdata,
      fw_done=>ack,fw_data=>data,fw_busy=>busy,fw_release=>release_cs);
   process(clk)
      variable countdown : integer := -1;
      variable is_write : boolean;
      variable saved_lane : natural;
      variable saved_byte : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk) then
         clocks <= clocks+1; ack<='0';
         if release_cs='1' then releases<=releases+1; end if;
         if req='1' or wr='1' then
            assert countdown=-1 report "SPI issued a request while backing was busy" severity failure;
            assert not(req='1' and wr='1') severity failure;
            countdown:=delay_cycles;is_write:=wr='1';
            saved_lane:=to_integer(lane);saved_byte:=wdata;
            if is_write then writes<=writes+1; else reads<=reads+1; end if;
         elsif countdown=0 then
            ack<='1';ack_at<=clocks;countdown:=-1;
            if is_write then
               memory_word(saved_lane*8+7 downto saved_lane*8)<=saved_byte;
               data<=x"DEADBEEF"; -- must not overwrite SPI's program-byte echo
            else data<=memory_word; end if;
         elsif countdown>0 then countdown:=countdown-1;
         end if;
      end if;
   end process;
   process
      variable value : std_logic_vector(7 downto 0);
      variable before_release : natural;
      procedure control(v : std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk);bus7.Din<=x"0000"&v;
         bus7.rnw<='0';bus7.ena<='1';bus7.bEna<="0011";
         wait until falling_edge(clk);bus7.rnw<='1';bus7.ena<='0';bus7.bEna<="0000";
      end;
      procedure transfer(v : std_logic_vector(7 downto 0); variable got : out std_logic_vector(7 downto 0)) is
         variable guard : natural := 0;
      begin
         wait until falling_edge(clk);bus7.Din<=x"00"&v&x"0000";
         bus7.rnw<='0';bus7.ena<='1';bus7.bEna<="0100";
         wait until falling_edge(clk);bus7.rnw<='1';bus7.ena<='0';bus7.bEna<="0000";
         while q(7)='1' and guard<2500 loop
            wait until falling_edge(clk);guard:=guard+1;
         end loop;
         assert guard<2500 report "SPI did not finish backed transaction" severity failure;
         got:=q(23 downto 16);
      end;
      procedure address_zero is
         variable unused : std_logic_vector(7 downto 0);
      begin transfer(x"00",unused);transfer(x"00",unused);transfer(x"00",unused);end;
   begin
      wait for 30 ns;wait until falling_edge(clk);reset<='0';
      control(x"8900");transfer(x"06",value);control(x"0000");
      control(x"8900");transfer(x"0A",value);address_zero;
      before_release:=releases;
      transfer(x"5A",value);
      assert writes=1 and value=x"5A" and memory_word=x"7654325A"
         report "write ack/echo/byte behavior mismatch" severity failure;
      assert clocks-ack_at<=4 report "busy timer wrapped during write backpressure" severity failure;
      assert releases=before_release report "program released while CS held" severity failure;
      busy<='1';control(x"0000");wait for 20 ns;
      assert releases=before_release+1 report "program disable did not request persistence" severity failure;
      control(x"8900");transfer(x"05",value);transfer(x"00",value);
      assert value=x"03" report "RDSR did not expose persistent busy+WEL" severity failure;
      busy<='0';transfer(x"00",value);
      assert value=x"02" report "RDSR busy did not clear after durable commit" severity failure;
      control(x"0000");wait for 20 ns;
      assert releases=before_release+1 report "status command spuriously requested persistence" severity failure;
      delay_cycles<=1100;
      control(x"8900");transfer(x"03",value);address_zero;transfer(x"00",value);
      assert value=x"5A" and reads=1 report "read acknowledgement/lane mismatch" severity failure;
      assert clocks-ack_at<=4 report "busy timer wrapped during read backpressure" severity failure;
      control(x"0000");
      -- Command02 has the same durable backing. Clearing HOLD on the final
      -- byte emits one release even though the data acknowledgement is late.
      control(x"8900");transfer(x"02",value);address_zero;
      control(x"8100");before_release:=releases;transfer(x"A6",value);
      assert value=x"A6" and writes=2 and releases=before_release+1
         report "final-byte CS release or command02 ack failed" severity failure;
      control(x"0000");wait for 20 ns;
      assert releases=before_release+1 report "duplicate release after final byte" severity failure;
      -- A short backing delay must fit inside the original 64-clock SPI byte.
      delay_cycles<=2;control(x"8900");transfer(x"03",value);address_zero;
      transfer(x"00",value);assert value=x"A6" severity failure;
      control(x"0000");
      report "PASS: SPI delayed read/write acknowledgements, no timer wrap, persistent RDSR, program02/0A release and write echo";
      stop;
   end process;
   process begin wait for 1 ms;assert false report "SPI backpressure test timeout" severity failure;end process;
end architecture;
