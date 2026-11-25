-- SPDX-License-Identifier: GPL-3.0-or-later
-- Verify the production scaler's nearest pixels start at the reported border.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_nds_pixel_grid_scaler is
    generic (SCALE : positive := 4);
end entity;
architecture test of tb_nds_pixel_grid_scaler is
    signal clk : std_logic := '0';
    signal mem_clk : std_logic := '0';
    signal reset_na : std_logic := '0';
    signal r,g,b : unsigned(7 downto 0);
    signal hs,vs,de,brd : std_logic;
    signal sw,sh,iw,ih,rw,rh : unsigned(11 downto 0);
    signal address : std_logic_vector(27 downto 0);
    signal read_request, valid : std_logic := '0';
    signal burst : std_logic_vector(7 downto 0);
    signal data : std_logic_vector(127 downto 0) := (others=>'0');
begin
    clk <= not clk after 5 ns;
    mem_clk <= not mem_clk after 2 ns;
    reset_na <= '1' after 300 ns;
    scaler: entity work.ascal generic map (
        RAMBASE=>x"00000000", NEAREST_ONLY=>true, ADAPTIVE=>false,
        DOWNSCALE_NN=>true, FRAC=>8, OHRES=>2304, IHRES=>2048,
        N_DW=>128, N_AW=>28, N_BURST=>256, PALETTE2=>false)
    port map (
        reset_na=>reset_na, i_clk=>clk, i_ce=>'0', i_capture_disable=>'1',
        i_r=>x"00", i_g=>x"00", i_b=>x"00", i_hs=>'0', i_vs=>'0', i_fl=>'0', i_de=>'0',
        o_clk=>clk, o_ce=>'1', o_r=>r, o_g=>g, o_b=>b,
        o_hs=>hs, o_vs=>vs, o_de=>de, o_brd=>brd, o_vbl=>open, o_lltune=>open,
        o_source_width=>sw, o_source_height=>sh, o_image_width=>iw, o_image_height=>ih,
        o_raster_width=>rw, o_raster_height=>rh,
        o_fb_ena=>'1', o_fb_hsize=>16, o_fb_vsize=>12,
        o_fb_format=>"000110", o_fb_base=>x"00000000", o_fb_stride=>to_unsigned(64,14),
        mode=>"01000", htotal=>512, hsstart=>400, hsend=>420, hdisp=>128,
        hmin=>11, hmax=>11+16*SCALE-1, vtotal=>80, vsstart=>68, vsend=>72,
        vdisp=>64, vmin=>2, vmax=>2+12*SCALE-1, i_hdmax=>open, i_vdmax=>open,
        poly_clk=>clk, poly_dw=>(others=>'0'), poly_a=>(others=>'0'), poly_wr=>'0',
        avl_clk=>mem_clk, avl_waitrequest=>'0', avl_readdata=>data,
        avl_readdatavalid=>valid, avl_burstcount=>burst, avl_writedata=>open,
        avl_address=>address, avl_write=>open, avl_read=>read_request, avl_byteenable=>open);

    memory: process(mem_clk)
        variable remaining : natural := 0;
        variable next_address, index, value : natural := 0;
        variable beat : std_logic_vector(127 downto 0);
    begin
        if rising_edge(mem_clk) then
            valid<='0';
            if reset_na='0' then remaining:=0;
            else
                if read_request='1' then
                    assert remaining=0 report "overlapping memory requests" severity failure;
                    next_address:=to_integer(unsigned(address));
                    remaining:=to_integer(unsigned(burst));
                end if;
                if remaining>0 then
                    for p in 0 to 3 loop
                        index:=next_address*4+p;
                        value:=(10+(index mod 16)*11+(index/16)*3) mod 256;
                        for byte in 0 to 3 loop
                            beat(p*32+byte*8+7 downto p*32+byte*8):=std_logic_vector(to_unsigned(value,8));
                        end loop;
                    end loop;
                    data<=beat; valid<='1';
                    remaining:=remaining-1;next_address:=next_address+1;
                end if;
            end if;
        end if;
    end process;

    check: process
        variable frames, x, y, checked, expected : natural := 0;
        variable old_vs, old_picture, picture : boolean := false;
    begin
        wait until falling_edge(clk);
        if vs='1' and not old_vs then frames:=frames+1;x:=0;y:=0;end if;
        old_vs:=vs='1';
        picture:=de='1' and brd='0';
        if old_picture and not picture then x:=0;y:=y+1;end if;
        if picture then
            if frames>=4 then
                assert sw=16 and sh=12 and iw=16*SCALE and ih=12*SCALE and rw=128 and rh=64
                    report "wrong exported scaler geometry" severity failure;
                expected:=10+(x/SCALE)*11+(y/SCALE)*3;
                assert r=expected and g=expected and b=expected
                    report "pixel boundary mismatch scale=" & integer'image(SCALE) &
                    " x=" & integer'image(x) & " y=" & integer'image(y) &
                    " expected=" & integer'image(expected) & " actual=" & integer'image(to_integer(r))
                    severity failure;
                checked:=checked+1;
            end if;
            x:=x+1;
        end if;
        old_picture:=picture;
        if frames=6 then
            assert checked=2*16*12*SCALE*SCALE report "missing scaler pixels" severity failure;
            report "PASS real nearest scaler: scale=" & integer'image(SCALE) & " pixels=" & integer'image(checked);
            stop;
        end if;
    end process;
    watchdog: process begin wait for 10 ms;assert false report "scaler timeout" severity failure;end process;
end architecture;
