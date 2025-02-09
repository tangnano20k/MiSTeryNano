// video.v

module video (
	      input	   clk,
	      
	      output	   clk_32,
	      output	   pll_lock,

	      input	   vs_in_n,
	      input	   hs_in_n,
	      input	   de_in,
	      input [3:0]  r_in,
	      input [3:0]  g_in,
	      input [3:0]  b_in,

          input [15:0] audio_l,
          input [15:0] audio_r,

          // interface to show directory on OSD
          input [1:0]  osd_btn_in,
          output       osd_btn_out,
          output [7:0] osd_dir_row,
          output [3:0] osd_dir_col,
          input [7:0]  osd_dir_chr,
          input [5:0]  osd_dir_len,   // up to 32 entries
          output [7:0] osd_file,
          output       osd_file_selected,
		 
	      // hdmi/tdms
	      output	   tmds_clk_n,
	      output	   tmds_clk_p,
	      output [2:0] tmds_d_n,
	      output [2:0] tmds_d_p  
	      );
   
wire clk_pixel_x5;   // 160 MHz HDMI clock
wire clk_pixel;      // at 800x576@50Hz the pixel clock is 32 MHz

assign clk_32 = clk_pixel;
    
`define PIXEL_CLOCK 32000000
pll_160m pll_hdmi (
               .clkout(clk_pixel_x5),
               .lock(pll_lock),
               .clkin(clk)
	       );
   
Gowin_CLKDIV clk_div_5 (
        .hclkin(clk_pixel_x5), // input hclkin
        .resetn(pll_lock),     // input resetn
        .clkout(clk_pixel)     // output clkout
    );


/* -------------------- HDMI video and audio -------------------- */

// generate 48khz audio clock
reg clk_audio;
reg [8:0] aclk_cnt;
always @(posedge clk_pixel) begin
    // divisor = pixel clock / 48000 / 2 - 1
    if(aclk_cnt < `PIXEL_CLOCK / 48000 / 2 -1)
        aclk_cnt <= aclk_cnt + 9'd1;
    else begin
        aclk_cnt <= 9'd0;
        clk_audio <= ~clk_audio;
    end
end

wire vreset;
wire [1:0] vmode;

video_analyzer video_analyzer (
   .clk(clk_pixel),
   .vs(vs_in_n),
   .hs(hs_in_n),
   .de(de_in),

   .mode(vmode),
   .vreset(vreset)  // reset signal
);  

wire sd_hs_n, sd_vs_n; 
wire [5:0] sd_r;
wire [5:0] sd_g;
wire [5:0] sd_b;
  
scandoubler #(10) scandoubler (
        // system interface
        .clk_sys(clk_pixel),
        .bypass(vmode == 2'd2),      // bypass in ST high/mono
        .ce_divider(1'b1),
        .pixel_ena(),

        // scanlines (00-none 01-25% 10-50% 11-75%)
        .scanlines(2'b00),

        // shifter video interface
        .hs_in(hs_in_n),
        .vs_in(vs_in_n),
        .r_in( r_in ),
        .g_in( g_in ),
        .b_in( b_in ),

        // output interface
        .hs_out(sd_hs_n),
        .vs_out(sd_vs_n),
        .r_out(sd_r),
        .g_out(sd_g),
        .b_out(sd_b)
);

wire [5:0] osd_r;
wire [5:0] osd_g;
wire [5:0] osd_b;  
   
osd_ascii osd_ascii (
        .clk(clk_pixel),
        .reset(!pll_lock),

        // directory listing interface
        .btn_in(osd_btn_in),
        .btn_out(osd_btn_out),
        .dir_row(osd_dir_row),
        .dir_col(osd_dir_col),
        .dir_chr(osd_dir_chr),
        .dir_len(osd_dir_len),
        .file_selected(osd_file_selected),
        .file_index(osd_file),

        // scandoubler video interface
        .hs(sd_hs_n),
        .vs(sd_vs_n),
		     
        .r_in(sd_r),
        .g_in(sd_g),
        .b_in(sd_b),
		     
        .r_out(osd_r),
        .g_out(osd_g),
        .b_out(osd_b)
);   
  
wire [2:0] tmds;
wire tmds_clock;

hdmi #(
    .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
    .VENDOR_NAME( { "MiSTle", 16'd0} ),
    .PRODUCT_DESCRIPTION( {"Atari ST", 64'd0} )
) hdmi(
  .clk_pixel_x5(clk_pixel_x5),
  .clk_pixel(clk_pixel),
  .clk_audio(clk_audio),
  .audio_sample_word( { audio_l, audio_r } ),
  .tmds(tmds),
  .tmds_clock(tmds_clock),

  // video input
  .stmode(vmode),    // current video mode PAL/NTSC/MONO
  .reset(vreset),    // signal to synchronize HDMI

  // Atari STE outputs 4 bits per color. Scandoubler outputs 6 bits (to be
  // able to implement dark scanlines) and HDMI expects 8 bits per color
  .rgb( { osd_r, 2'b00, osd_g, 2'b00, osd_b, 2'b00 } )
);

// differential output
ELVDS_OBUF tmds_bufds [3:0] (
        .I({tmds_clock, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
);

endmodule
