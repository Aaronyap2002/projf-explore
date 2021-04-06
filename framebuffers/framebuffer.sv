// Project F: Framebuffers - Framebuffer in BRAM (Indexed Colour)
// (C)2021 Will Green, Open Source Hardware released under the MIT License
// Learn more at https://projectf.io

`default_nettype none
`timescale 1ns / 1ps

// NB. Signals are in clk_sys domain unless indicated

module framebuffer #(
    parameter CORDW=16,      // signed coordinate width (bits)
    parameter WIDTH=160,     // width of framebuffer in pixels
    parameter HEIGHT=120,    // height of framebuffer in pixels
    parameter CIDXW=4,       // colour index data width: 4=16, 8=256 colours
    parameter CHANW=4,       // width of RGB colour channels (4 or 8 bit)
    parameter SCALE=4,       // display output scaling factor (>=1)
    parameter F_IMAGE="",    // image file to load into framebuffer
    parameter F_PALETTE=""   // palette file to load into CLUT
    ) (
    input  wire logic clk_sys,    // system clock
    input  wire logic clk_pix,    // pixel clock
    input  wire logic de,         // data enable for display (clk_pix)
    input  wire logic frame,      // start a new frame (clk_pix)
    input  wire logic line,       // start a new screen line (clk_pix)
    input  wire logic we,         // write enable
    input  wire logic signed [CORDW-1:0] x,  // horizontal pixel coordinate
    input  wire logic signed [CORDW-1:0] y,  // vertical pixel coordinate
    input  wire logic [CIDXW-1:0] cidx,   // framebuffer colour index
    output      logic clip,               // pixel coordinate outside buffer
    output      logic [CHANW-1:0] red,    // colour output to display (clk_pix)
    output      logic [CHANW-1:0] green,  //     "    "    "    "    "
    output      logic [CHANW-1:0] blue    //     "    "    "    "    "
    );

    logic frame_sys;  // start of new frame in system clock domain
    xd xd_frame (.clk_i(clk_pix), .clk_o(clk_sys), .i(frame), .o(frame_sys));

    // framebuffer (FB)
    localparam FB_PIXELS = WIDTH * HEIGHT;
    localparam FB_DEPTH  = FB_PIXELS;  // single buffer
    localparam FB_ADDRW  = $clog2(FB_DEPTH);
    localparam FB_DATAW  = CIDXW;

    logic [FB_ADDRW-1:0] fb_addr_read, fb_addr_write;
    logic [FB_DATAW-1:0] fb_cidx_read, fb_cidx_read_p1;

    // calculate write address from pixel coordinates (two stage: mul then add)
    logic signed [CORDW-1:0] x_add;
    logic [FB_ADDRW-1:0] pix_addr_line;
    always_ff @(posedge clk_sys) begin
        if (y < 0 || y >= HEIGHT || x < 0 || x >= WIDTH) begin
            clip <= 1;
            pix_addr_line <= 0;
            x_add <= 0;
        end else begin
            clip <= 0;
            /* verilator lint_off WIDTH */
            pix_addr_line <= WIDTH * y;
            /* verilator lint_on WIDTH */
            x_add <= x;  // save x for next stage
        end
        /* verilator lint_off WIDTH */
        fb_addr_write <= pix_addr_line + x_add;
        /* verilator lint_on WIDTH */
    end

    // write to pixel address (delay to match address calculation)
    logic fb_we, we_in_p1;
    logic [FB_DATAW-1:0] fb_cidx_write, cidx_in_p1;
    always_ff @(posedge clk_sys) begin
        we_in_p1 <= we;
        cidx_in_p1 <= cidx;
        fb_we <= (clip == 0) ? we_in_p1 : 0;  // write enable if not clipped
        fb_cidx_write <= cidx_in_p1;
    end

    // framebuffer memory (BRAM)
    bram_sdp #(
        .WIDTH(FB_DATAW),
        .DEPTH(FB_DEPTH),
        .INIT_F(F_IMAGE)
    ) bram_inst (
        .clk_write(clk_sys),
        .clk_read(clk_sys),
        .we(fb_we),
        .addr_write(fb_addr_write),
        .addr_read(fb_addr_read),
        .data_in(fb_cidx_write),
        .data_out(fb_cidx_read)
    );

    // linebuffer (LB)
    localparam LB_SCALE = SCALE;  // scale (horizontal and vertical)
    localparam LB_LEN   = WIDTH;  // line length matches framebuffer
    localparam LB_BPC   = CHANW;  // bits per colour channel

    // Load data from FB into LB
    logic lb_data_req;  // LB requesting data
    logic [$clog2(LB_LEN+1)-1:0] cnt_h;  // count pixels in line to read
    always_ff @(posedge clk_sys) begin
        if (lb_data_req) begin
            cnt_h <= 0;  // start new line
        end else if (cnt_h < LB_LEN) begin  // advance to start of next line
            cnt_h <= cnt_h + 1;
            fb_addr_read <= fb_addr_read + 1;
        end
        if (frame_sys) fb_addr_read <= 0;  // new frame
    end

    // LB enable (not corrected for latency)
    logic lb_en_in, lb_en_out;
    always_comb lb_en_in  = (cnt_h < LB_LEN);
    always_comb lb_en_out = de;

    // LB enable in: address calc and CLUT reg add three cycles of latency
    localparam LAT = 3;  // write latency
    logic [LAT-1:0] lb_en_in_sr;
    always @(posedge clk_sys) lb_en_in_sr <= {lb_en_in, lb_en_in_sr[LAT-1:1]};

    // LB colour channels
    logic [LB_BPC-1:0] lb_in_0,  lb_in_1,  lb_in_2;
    logic [LB_BPC-1:0] lb_out_0, lb_out_1, lb_out_2;

    linebuffer #(
        .WIDTH(LB_BPC),   // data width of each channel
        .LEN(LB_LEN),     // length of line
        .SCALE(LB_SCALE)  // scaling factor (>=1)
        ) lb_inst (
        .clk_in(clk_sys),        // input clock
        .clk_out(clk_pix),       // output clock
        .data_req(lb_data_req),  // request input data (clk_in)
        .en_in(lb_en_in_sr[0]),  // enable input (clk_in)
        .en_out(lb_en_out),      // enable output (clk_out)
        .frame,                  // start a new frame (clk_out)
        .line,                   // start a new line (clk_out)
        .din_0(lb_in_0),         // data in (clk_in)
        .din_1(lb_in_1),
        .din_2(lb_in_2),
        .dout_0(lb_out_0),       // data out (clk_out)
        .dout_1(lb_out_1),
        .dout_2(lb_out_2)
    );

    // improve timing with register between BRAM and async ROM
    always @(posedge clk_sys) fb_cidx_read_p1 <= fb_cidx_read;

    // colour lookup table (ROM)
    localparam CLUTW = 3 * CHANW;
    logic [CLUTW-1:0] clut_colr;
    rom_async #(
        .WIDTH(CLUTW),
        .DEPTH(2**CIDXW),
        .INIT_F(F_PALETTE)
    ) clut (
        .addr(fb_cidx_read_p1),
        .data(clut_colr)
    );

    // map colour index to palette using CLUT and read into LB
    always_ff @(posedge clk_sys) {lb_in_2, lb_in_1, lb_in_0} <= clut_colr;

    logic lb_en_out_p1;  // LB enable out: reading from LB BRAM takes one cycle
    always_ff @(posedge clk_pix) lb_en_out_p1 <= lb_en_out;

    // colour output - combinational because top module should register
    always_comb begin
        red   = lb_en_out_p1 ? lb_out_2 : 0;
        green = lb_en_out_p1 ? lb_out_1 : 0;
        blue  = lb_en_out_p1 ? lb_out_0 : 0;
    end
endmodule