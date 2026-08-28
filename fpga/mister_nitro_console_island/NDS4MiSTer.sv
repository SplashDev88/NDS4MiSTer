// SPDX-License-Identifier: GPL-3.0-or-later
// r355 prune-first Nitro console island under the retained NDS4MiSTer shell.
// The prior r343 project is not edited; this alternate project is default-off
// by virtue of its separate QPF/QSF and output name.
module emu
(
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='Z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='Z;
    assign VGA_F1=0;
    assign VGA_SCALER=0;
    assign VGA_DISABLE=0;
    assign HDMI_FREEZE=0;
    assign HDMI_BLACKOUT=0;
    assign HDMI_BOB_DEINT=0;
    assign AUDIO_S=1;
    assign AUDIO_MIX=0;
    assign LED_DISK=0;
    assign LED_POWER=0;
    assign BUTTONS=0;
    `include "build_id.v"
    // Keep the MiSTer folder key equal to the proven NDS core identity.
    // Put the alpha label in the version line, not in the core-name field.
    localparam CONF_STR={
        "NDS;;",
        "FS3,NDS,Load NDS (max 128 MiB),30000000;",
        "-;",
        "O[6:5],Video Layout,Left/Right,Top/Bottom,Left Only,Right Only;",
        "O[7],Screen Order,Main First,Touch First;",
        // MiSTer initializes a new config version to option value zero. Keep
        // the user-facing default at eight pixels while retaining None.
        "O[9:8],Screen Gap,8 Pixels,None,16 Pixels,24 Pixels;",
        "O[4],FPS Counter,Off,On;",
        "T[0],Reset;",
        "J1,A,B,X,Y,L,R,Select,Start,Touch;",
        "v,1;",
        "V,r355 Nitro console island v",`BUILD_DATE
    };

    wire [1:0] buttons;
    wire [127:0] status;
    wire [31:0] joystick_0,joystick_1;
    // The right stick is the absolute DS touchscreen position. Keep the left
    // stick free for games and future control mappings.
    wire [15:0] touch_analog_0;
    wire forced_scandoubler;
    wire [21:0] gamma_bus;
    wire ioctl_download;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_dout;
    wire ioctl_wr;
    wire [15:0] ioctl_index;
    wire ioctl_wait;
    wire save_img_mounted;
    wire save_img_readonly;
    wire [63:0] save_img_size;
    wire [31:0] save_sd_lba;
    wire save_sd_rd;
    wire save_sd_wr;
    wire save_sd_ack;
    wire [12:0] save_sd_buff_addr;
    wire [15:0] save_sd_buff_dout;
    wire [15:0] save_sd_buff_din;
    wire save_sd_buff_wr;
    wire [1:0] video_layout_active;
    wire video_screen_order_active;
    wire [1:0] video_gap_active;
    wire video_fps_active;
    // Translate the menu ordering back to scanout's 0/1/2/3 =
    // 0/8/16/24-pixel ABI.
    wire [1:0] video_gap_select = status[9:8] == 2'd0 ? 2'd1 :
                                  status[9:8] == 2'd1 ? 2'd0 :
                                  status[9:8];

    // Request the largest exact integer multiple of the frame-boundary-latched
    // source canvas. This keeps menu changes and scaler geometry atomic.
    nds_nitro_integer_scale integer_scale (
        .hdmi_width(HDMI_WIDTH),.hdmi_height(HDMI_HEIGHT),
        .layout(video_layout_active),.gap(video_gap_active),
        .fps_enabled(video_fps_active),
        .video_arx(VIDEO_ARX),.video_ary(VIDEO_ARY)
    );

    wire clk_sys,shell_pll_locked;
    pll pll(
        .refclk(CLK_50M),.rst(1'b0),
        .outclk_0(clk_sys),.locked(shell_pll_locked)
    );

    wire nitro_clk_mem,nitro_clk2x,nitro_clk1x,nitro_pll_locked;
    nitro_pll island_pll(
        .refclk(CLK_50M),.rst(1'b0),
        .outclk_0(nitro_clk_mem),
        .outclk_1(nitro_clk2x),
        .outclk_2(nitro_clk1x),
        .locked(nitro_pll_locked)
    );

    hps_io #(.CONF_STR(CONF_STR),.WIDE(1)) hps_io(
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),
        .gamma_bus(gamma_bus),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .joystick_r_analog_0(touch_analog_0),
        .forced_scandoubler(forced_scandoubler),
        .buttons(buttons),.status(status),
        .ioctl_download(ioctl_download),.ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_wait(ioctl_wait),
        .img_mounted(save_img_mounted),
        .img_readonly(save_img_readonly),.img_size(save_img_size),
        .sd_lba('{save_sd_lba}),.sd_blk_cnt('{6'd0}),
        .sd_rd(save_sd_rd),.sd_wr(save_sd_wr),.sd_ack(save_sd_ack),
        .sd_buff_addr(save_sd_buff_addr),
        .sd_buff_dout(save_sd_buff_dout),
        .sd_buff_din('{save_sd_buff_din}),.sd_buff_wr(save_sd_buff_wr)
    );

    wire core_reset=RESET|status[0]|buttons[1]|~shell_pll_locked;
    // The Nitro console is the only execution path in this core. It is always
    // enabled, so the OSD no longer exposes a misleading on/off switch.
    wire console_enabled=1'b1;

    // ---------------- Nitro execution island ----------------
    wire nitro_ce,nitro_de,nitro_hs,nitro_vs;
    wire [7:0] nitro_r,nitro_g,nitro_b;
    wire nitro_boot_done,nitro_boot_error,nitro_cart_loaded;
    wire nitro_boundary_fault;
    wire [15:0] nitro_audio_left,nitro_audio_right;
    wire [7:0] island_ddr_burst;
    wire [28:0] island_ddr_addr;
    wire [63:0] island_ddr_dout,island_ddr_din;
    wire [7:0] island_ddr_be;
    wire island_ddr_read,island_ddr_write,island_ddr_busy;
    wire island_ddr_dout_ready;

    nds_nitro_console_island island(
        .clk1x(nitro_clk1x),.clk2x(nitro_clk2x),
        .clk_mem(nitro_clk_mem),.clk_video(clk_sys),.ddr_clk(clk_sys),
        .island_locked(nitro_pll_locked),.shell_reset(core_reset),
        .enable(console_enabled),
        .video_layout_select(status[6:5]),
        .video_screen_order_select(status[7]),
        .video_gap_select(video_gap_select),
        .video_fps_select(status[4]),
        .video_layout_active,.video_screen_order_active,
        .video_gap_active,.video_fps_active,
        .joystick(joystick_0),.joystick_analog(touch_analog_0),
        .ioctl_download,.ioctl_index,.ioctl_wait,
        .save_img_mounted,.save_img_readonly,.save_img_size,
        .save_sd_lba,.save_sd_rd,.save_sd_wr,.save_sd_ack,
        .save_sd_buff_addr,.save_sd_buff_dout,
        .save_sd_buff_din,.save_sd_buff_wr,
        .boot_done(nitro_boot_done),.boot_error(nitro_boot_error),
        .cart_loaded(nitro_cart_loaded),
        .video_ce(nitro_ce),.video_de(nitro_de),
        .video_hs(nitro_hs),.video_vs(nitro_vs),
        .video_r(nitro_r),.video_g(nitro_g),.video_b(nitro_b),
        .boundary_fault(nitro_boundary_fault),
        .audio_left(nitro_audio_left),.audio_right(nitro_audio_right),
        .island_ddr_burst,.island_ddr_addr,.island_ddr_dout,
        .island_ddr_dout_ready,.island_ddr_read,.island_ddr_din,
        .island_ddr_be,.island_ddr_write,.island_ddr_busy,
        .SDRAM_CLK,.SDRAM_CKE,.SDRAM_A,.SDRAM_BA,.SDRAM_DQ,
        .SDRAM_DQML,.SDRAM_DQMH,.SDRAM_nCS,.SDRAM_nCAS,
        .SDRAM_nRAS,.SDRAM_nWE
    );

    // The island owns the one physical DDR port.  Its outer fabric preserves
    // the legacy 0x30000000 ROM/framebuffer controller as client zero and adds
    // the disjoint H3D control/ring/plane window at 0x3fc00000..0x3fd7ffff.
    // Burst response ownership and bounded plane priority are proven inside
    // the island; the retained shell therefore remains a single DDR master.
    assign island_ddr_busy=DDRAM_BUSY;
    assign island_ddr_dout=DDRAM_DOUT;
    assign island_ddr_dout_ready=DDRAM_DOUT_READY;
    assign DDRAM_BURSTCNT=island_ddr_burst;
    assign DDRAM_ADDR=island_ddr_addr;
    assign DDRAM_RD=island_ddr_read;
    assign DDRAM_DIN=island_ddr_din;
    assign DDRAM_BE=island_ddr_be;
    assign DDRAM_WE=island_ddr_write;
    assign DDRAM_CLK=clk_sys;

    // ---------------- Retained final video/audio electrical contract --------
    assign CLK_VIDEO=clk_sys;
    assign CE_PIXEL=nitro_ce;
    assign VGA_DE=nitro_de;
    assign VGA_HS=nitro_hs;
    assign VGA_VS=nitro_vs;
    assign VGA_R=nitro_r;
    assign VGA_G=nitro_g;
    assign VGA_B=nitro_b;
    assign VGA_SL=2'b00;

    assign AUDIO_L=nitro_audio_left;
    assign AUDIO_R=nitro_audio_right;

    // Direct-to-DDR host loads do not emit per-beat ioctl_wr and report their
    // file size through only the 27-bit ioctl_addr field.  A >128 MiB image is
    // therefore indistinguishable from its wrapped size in fabric.  The OSD
    // label is the user-visible first-beta preflight contract; the donor card
    // address port itself spans exactly 128 MiB.
    assign LED_USER=nitro_boot_error|nitro_boundary_fault|~nitro_cart_loaded;
endmodule
