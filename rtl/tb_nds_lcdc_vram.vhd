-- SPDX-License-Identifier: GPL-3.0-or-later
-- Exercise the actual VRAM service's LCDC selection and paired-word cache.
-- The synthetic backing port returns bank/address signatures after reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_lcdc_vram is end;
architecture sim of tb_nds_lcdc_vram is
   signal clk : std_logic := '0';
   signal reset : std_logic := '1';
   signal maps : std_logic_vector(71 downto 0) := (others=>'0');
   signal clear_busy, srv_req, req, accept, done, lcdc : std_logic := '0';
   signal addr : unsigned(18 downto 2) := (others=>'0');
   signal data : std_logic_vector(31 downto 0);
   signal rsreq, rsready, rsdone : std_logic := '0';
   signal rsbank : std_logic_vector(1 downto 0);
   signal rsaddr : unsigned(16 downto 3);
   signal rsdata : std_logic_vector(63 downto 0) := (others=>'0');
   signal cycles : natural := 0;
   signal stream_mode, stream_start, stream_busy, stream_req, stream_we : std_logic := '0';
   signal stream_addr : integer range 0 to 131071;
   signal stream_bank : std_logic_vector(1 downto 0) := "00";
   signal stream_line : integer range 0 to 191 := 0;
   signal stream_x : integer range 0 to 255;
   signal stream_y : integer range 0 to 191;
   signal stream_data : std_logic_vector(17 downto 0);
   signal effective_req, effective_lcdc : std_logic;
   signal effective_addr : unsigned(18 downto 2);
   function signature(b,a : natural) return std_logic_vector is
   begin return x"A0" & std_logic_vector(to_unsigned(b,8)) & std_logic_vector(to_unsigned(a,16)); end;
begin
   clk<=not clk after 5 ns;
   effective_req <= stream_req when stream_mode='1' else req;
   effective_lcdc <= '1' when stream_mode='1' else lcdc;
   effective_addr <= to_unsigned(stream_addr,17) when stream_mode='1' else addr;
   reader : entity work.nds_lcdc_line port map(
      clk=>clk,reset=>reset,start=>stream_start,line_y=>stream_line,bank=>stream_bank,
      busy=>stream_busy,mem_req=>stream_req,mem_addr=>stream_addr,
      mem_accept=>accept,mem_done=>done,mem_data=>data,
      pixel_we=>stream_we,pixel_x=>stream_x,pixel_y=>stream_y,pixel_data=>stream_data);
   dut : entity work.nds_vram generic map(is_simu=>'1') port map(
      clk=>clk,reset=>reset,vramcnt=>maps,
      cpu9_ena=>'0',cpu9_rnw=>'1',cpu9_addr=>(others=>'0'),cpu9_be=>"0000",cpu9_din=>(others=>'0'),
      cpu9_dout=>open,cpu9_done=>open,cpu9_welig=>open,cpu9_wok=>open,
      cpu7_ena=>'0',cpu7_rnw=>'1',cpu7_addr=>(others=>'0'),cpu7_be=>"0000",cpu7_din=>(others=>'0'),
      cpu7_dout=>open,cpu7_done=>open,
      srv_req=>srv_req,srv_rnw=>open,srv_bank=>open,srv_addr=>open,srv_be=>open,srv_din=>open,
      srv_dout=>(others=>'0'),srv_done=>srv_req,
      rdr_bg_req=>effective_req,rdr_bg_lcdc=>effective_lcdc,rdr_bg_addr=>effective_addr,rdr_bg_accept=>accept,rdr_bg_done=>done,rdr_bg_dout=>data,
      rsrv_req=>rsreq,rsrv_ready=>rsready,rsrv_bank=>rsbank,rsrv_addr=>rsaddr,rsrv_done=>rsdone,rsrv_dout=>rsdata,
      clr_busy=>clear_busy,dbg_rbusy=>open);
   rsready<='1' when cycles mod 5/=2 else '0';
   process(clk)
      variable b,a : natural;
      type data_queue_t is array(0 to 63) of std_logic_vector(63 downto 0);
      type time_queue_t is array(0 to 63) of natural;
      variable queue : data_queue_t;
      variable deadline : time_queue_t;
      variable head,tail,count : natural := 0;
   begin
      if rising_edge(clk) then
         cycles<=cycles+1;rsdone<='0';
         if rsreq='1' and rsready='1' then
            b:=to_integer(unsigned(rsbank));a:=to_integer(rsaddr)*2;
            assert count<64 report "synthetic VRAM response queue overflow" severity failure;
            queue(tail):=signature(b,a+1)&signature(b,a);
            deadline(tail):=cycles+31;
            tail:=(tail+1) mod 64;count:=count+1;
         end if;
         if count>0 and cycles>=deadline(head) then
            rsdata<=queue(head);rsdone<='1';head:=(head+1) mod 64;count:=count-1;
         end if;
      end if;
   end process;
   process
      procedure readword(mode : std_logic; wordaddr : natural; expected : std_logic_vector(31 downto 0)) is
      begin
         wait until falling_edge(clk);lcdc<=mode;addr<=to_unsigned(wordaddr,17);req<='1';
         wait until rising_edge(clk) and accept='1';req<='0';
         wait until rising_edge(clk) and done='1';
         assert data=expected report "LCDC VRAM mapping/paired word mismatch" severity failure;
         wait until falling_edge(clk);
      end;
      variable expected_word : std_logic_vector(31 downto 0);
      variable expected_half : std_logic_vector(15 downto 0);
      variable expected_color : std_logic_vector(17 downto 0);
      variable y : natural;
   begin
      wait until falling_edge(clk);wait until falling_edge(clk);reset<='0';
      wait until clear_busy='0';wait until falling_edge(clk);
      for b in 0 to 3 loop
         maps<=(others=>'0');maps(b*8+7 downto b*8)<=x"80";
         readword('1',b*32768,signature(b,0));
         readword('1',b*32768+1,signature(b,1));
         readword('1',b*32768+24574,signature(b,24574));
         readword('1',b*32768+24575,signature(b,24575));
         maps(b*8+7 downto b*8)<=x"00";
         readword('1',b*32768+24575,x"00000000");
         maps(b*8+7 downto b*8)<=x"81";
         readword('1',b*32768,x"00000000");
         readword('0',0,signature(b,0));
         readword('0',1,signature(b,1));
      end loop;
      -- Exercise the real four-credit reader and VRAM queue together. Ordered
      -- replies arrive after 31 cycles while the backing port stalls accepts.
      -- This catches response/halfword alignment errors hidden by scalar reads.
      stream_mode<='1';maps<=x"000000000080808080";
      for b in 0 to 3 loop
         for line_case in 0 to 1 loop
            if line_case=0 then y:=0;else y:=191;end if;
            wait until falling_edge(clk);
            stream_bank<=std_logic_vector(to_unsigned(b,2));stream_line<=y;stream_start<='1';
            wait until falling_edge(clk);stream_start<='0';
            for x in 0 to 255 loop
               wait until rising_edge(clk) and stream_we='1';
               expected_word:=signature(b,y*128+x/2);
               if x mod 2=0 then expected_half:=expected_word(15 downto 0);
               else expected_half:=expected_word(31 downto 16);end if;
               expected_color:=expected_half(14 downto 10)&'0'&expected_half(9 downto 5)&'0'&expected_half(4 downto 0)&'0';
               assert stream_x=x and stream_y=y and stream_data=expected_color
                  report "streamed LCDC pixel/address/halfword mismatch" severity failure;
            end loop;
            wait until falling_edge(clk);
            assert stream_busy='0' report "streamed LCDC line did not finish" severity failure;
         end loop;
      end loop;
      report "PASS: actual VRAM LCDC banks, disabled/non-LCDC maps, normal BG and paired words" severity note;
      report "PASS: real four-credit LCDC reader through VRAM queue, all banks and edge lines" severity note;
      stop;wait;
   end process;
   process begin wait for 10 ms;assert false report "LCDC VRAM timeout" severity failure;end process;
end;
