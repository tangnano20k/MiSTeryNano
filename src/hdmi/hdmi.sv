// Implementation of HDMI Spec v1.4a
// By Sameer Puri https://github.com/sameer

// The original hdmi.sv generated its own timing completely independent.
// This version synchronizes to an external sync signal which is expected to
// have exactly half the horizontal refresh rate.

module hdmi 
#(
    // The IT content bit indicates that image samples are generated in an ad-hoc
    // manner (e.g. directly from values in a framebuffer, as by a PC video
    // card) and therefore aren't suitable for filtering or analog
    // reconstruction.  This is probably what you want if you treat pixels
    // as "squares".  If you generate a properly bandlimited signal or obtain
    // one from elsewhere (e.g. a camera), this can be turned off.
    //
    // This flag also tends to cause receivers to treat RGB values as full
    // range (0-255).
    parameter bit IT_CONTENT = 1'b1,

    // Defaults to minimum bit lengths required to represent positions.
    // Modify these parameters if you have alternate desired bit lengths.
    parameter int BIT_WIDTH = 11,
    parameter int BIT_HEIGHT = 10,

    // A true HDMI signal sends auxiliary data (i.e. audio, preambles) which prevents it from being parsed by DVI signal sinks.
    // HDMI signal sinks are fortunately backwards-compatible with DVI signals.
    // Enable this flag if the output should be a DVI signal. You might want to do this to reduce resource usage or if you're only outputting video.
    parameter bit DVI_OUTPUT = 1'b0,

    // **All parameters below matter ONLY IF you plan on sending auxiliary data (DVI_OUTPUT == 1'b0)**

    // As specified in Section 7.3, the minimal audio requirements are met: 16-bit or more L-PCM audio at 32 kHz, 44.1 kHz, or 48 kHz.
    // See Table 7-4 or README.md for an enumeration of sampling frequencies supported by HDMI.
    // Note that sinks may not support rates above 48 kHz.
    parameter int AUDIO_RATE = 44100,

    // Defaults to 16-bit audio, the minmimum supported by HDMI sinks. Can be anywhere from 16-bit to 24-bit.
    parameter int AUDIO_BIT_WIDTH = 16,

    // Some HDMI sinks will show the source product description below to users (i.e. in a list of inputs instead of HDMI 1, HDMI 2, etc.).
    // If you care about this, change it below.
    parameter bit [8*8-1:0] VENDOR_NAME = {"Unknown", 8'd0}, // Must be 8 bytes null-padded 7-bit ASCII
    parameter bit [8*16-1:0] PRODUCT_DESCRIPTION = {"FPGA", 96'd0}, // Must be 16 bytes null-padded 7-bit ASCII
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 8'h00, // See README.md or CTA-861-G for the list of valid codes

    // Starting screen coordinate when module comes out of reset.
    //
    // Setting these to something other than (0, 0) is useful when positioning
    // an external video signal within a larger overall frame (e.g.
    // letterboxing an input video signal). This allows you to synchronize the
    // negative edge of reset directly to the start of the external signal
    // instead of to some number of clock cycles before.
    //
    // You probably don't need to change these parameters if you are
    // generating a signal from scratch instead of processing an
    // external signal.
    parameter int START_X = 0,
    parameter int START_Y = 0
)
(
    input logic clk_pixel_x5,
    input logic clk_pixel,
    input logic clk_audio,
    // synchronous reset back to 0,0
    input logic reset,
    input logic [1:0] stmode,         // atari st video mode, 0=60hz ntsc, 1=50hz pal, 2=mono
    input logic [23:0] rgb,    
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    // These outputs go to your HDMI port
    output logic [2:0] tmds,
    output logic tmds_clock,
    
    // All outputs below this line stay inside the FPGA
    // They are used (by you) to pick the color each pixel should have
    // i.e. always_ff @(posedge pixel_clk) rgb <= {8'd0, 8'(cx), 8'(cy)};
    output logic [BIT_WIDTH-1:0] cx,
    output logic [BIT_HEIGHT-1:0] cy,

    // TODO: geometry should become input and be provided by the Atari video logic
    // depending on the current of the three possible video modes

    // The screen is at the upper left corner of the frame.
    // 0,0 = 0,0 in video
    // the frame includes extra space for sending auxiliary data
    output logic [BIT_WIDTH-1:0] frame_width,
    output logic [BIT_HEIGHT-1:0] frame_height,
    output logic [BIT_WIDTH-1:0] screen_width,
    output logic [BIT_HEIGHT-1:0] screen_height
);

localparam int NUM_CHANNELS = 3;
logic hsync;
logic vsync;

logic [BIT_WIDTH-1:0] hsync_pulse_start, hsync_pulse_size;
logic [BIT_HEIGHT-1:0] vsync_pulse_start, vsync_pulse_size;
logic [1:0] invert;

assign frame_width = (stmode==2'd0)?1016:(stmode==2'd1)?1024:896;
// is usually 800, but Atari ST in PAL outputs 840 pixels per line
// and (our) HDMI implementation expects the width to be a multiple of 16
// Also demos openeing the screen can only address 832 pixels properly
assign screen_width = (stmode==2'd0)?848:(stmode==2'd1)?832:640;
assign hsync_pulse_start = (stmode==2'd0)?16:24;
assign hsync_pulse_size = (stmode==2'd0)?62:72;
// should be 625/525, has to be 626/526 for Atari ST in PAL/NTSC mode
assign frame_height = (stmode==2'd0)?526:(stmode==2'd1)?626:501;
assign screen_height = (stmode==2'd0)?484:(stmode==2'd1)?576:400;
assign vsync_pulse_start = (stmode==2'd0)?9:5;
assign vsync_pulse_size = (stmode==2'd0)?6:5;
assign invert = 2'b11;

always_comb begin
    hsync <= invert[0] ^ (cx >= screen_width + hsync_pulse_start && cx < screen_width + hsync_pulse_start + hsync_pulse_size);
    // vsync pulses should begin and end at the start of hsync, so special
    // handling is required for the lines on which vsync starts and ends
    if (cy == screen_height + vsync_pulse_start)
        vsync <= invert[1] ^ (cx >= screen_width + hsync_pulse_start);
    else if (cy == screen_height + vsync_pulse_start + vsync_pulse_size)
        vsync <= invert[1] ^ (cx < screen_width + hsync_pulse_start);
    else
        vsync <= invert[1] ^ (cy >= screen_height + vsync_pulse_start && cy < screen_height + vsync_pulse_start + vsync_pulse_size);
end

localparam real VIDEO_RATE = 32E6;

// Wrap-around pixel position counters indicating the pixel to be generated by the user in THIS clock and sent out in the NEXT clock.
always_ff @(posedge clk_pixel)
begin
    if (reset)
    begin
        cx <= BIT_WIDTH'(START_X);
        cy <= BIT_HEIGHT'(START_Y);
    end
    else
    begin
        cx <= cx == frame_width-1'b1 ? BIT_WIDTH'(0) : cx + 1'b1;
        cy <= cx == frame_width-1'b1 ? cy == frame_height-1'b1 ? BIT_HEIGHT'(0) : cy + 1'b1 : cy;
    end
end

// See Section 5.2
logic video_data_period = 0;
always_ff @(posedge clk_pixel)
begin
    if (reset)
        video_data_period <= 0;
    else
        video_data_period <= cx < screen_width && cy < screen_height;
end

logic [2:0] mode = 3'd1;
logic [23:0] video_data = 24'd0;
logic [5:0] control_data = 6'd0;
logic [11:0] data_island_data = 12'd0;

generate
    if (!DVI_OUTPUT)
    begin: true_hdmi_output
        logic video_guard = 1;
        logic video_preamble = 0;
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                video_guard <= 1;
                video_preamble <= 0;
            end
            else
            begin
                video_guard <= cx >= frame_width - 2 && cx < frame_width && (cy == frame_height - 1 || cy < screen_height);
                video_preamble <= cx >= frame_width - 10 && cx < frame_width - 2 && (cy == frame_height - 1 || cy < screen_height);
            end
        end

        // See Section 5.2.3.1
        int max_num_packets_alongside;
        logic [4:0] num_packets_alongside;
        always_comb
        begin
            max_num_packets_alongside = ((frame_width - screen_width) /* VD period */ - 2 /* V guard */ - 8 /* V preamble */ - 12 /* 12px control period */ - 2 /* DI guard */ - 2 /* DI start guard */ - 8 /* DI premable */) / 32;
            if (max_num_packets_alongside > 18)
                num_packets_alongside = 5'd18;
            else
                num_packets_alongside = 5'(max_num_packets_alongside);
        end

        logic data_island_period_instantaneous;
        assign data_island_period_instantaneous = num_packets_alongside > 0 && cx >= screen_width + 10 && cx < screen_width + 10 + num_packets_alongside * 32;
        logic packet_enable;
        assign packet_enable = data_island_period_instantaneous && 5'(cx + screen_width + 22) == 5'd0;

        logic data_island_guard = 0;
        logic data_island_preamble = 0;
        logic data_island_period = 0;
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                data_island_guard <= 0;
                data_island_preamble <= 0;
                data_island_period <= 0;
            end
            else
            begin
                data_island_guard <= num_packets_alongside > 0 && ((cx >= screen_width + 8 && cx < screen_width + 10) || (cx >= screen_width + 10 + num_packets_alongside * 32 && cx < screen_width + 10 + num_packets_alongside * 32 + 2));
                data_island_preamble <= num_packets_alongside > 0 && cx >= screen_width && cx < screen_width + 8;
                data_island_period <= data_island_period_instantaneous;
            end
        end

        // See Section 5.2.3.4
        logic [23:0] header;
        logic [55:0] sub [3:0];
        logic video_field_end;
        assign video_field_end = cx == screen_width - 1'b1 && cy == screen_height - 1'b1;
        logic [4:0] packet_pixel_counter;
        packet_picker #(
            .VIDEO_RATE(VIDEO_RATE),
            .IT_CONTENT(IT_CONTENT),
            .AUDIO_RATE(AUDIO_RATE),
            .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
            .VENDOR_NAME(VENDOR_NAME),
            .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION),
            .SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)
        ) packet_picker (.clk_pixel(clk_pixel), .clk_audio(clk_audio), .reset(reset), .stmode(stmode), .video_field_end(video_field_end), .packet_enable(packet_enable), .packet_pixel_counter(packet_pixel_counter), .audio_sample_word(audio_sample_word), .header(header), .sub(sub));
        logic [8:0] packet_data;
        packet_assembler packet_assembler (.clk_pixel(clk_pixel), .reset(reset), .data_island_period(data_island_period), .header(header), .sub(sub), .packet_data(packet_data), .counter(packet_pixel_counter));


        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd2;
                video_data <= 24'd0;
                control_data = 6'd0;
                data_island_data <= 12'd0;
            end
            else
            begin
                mode <= data_island_guard ? 3'd4 : data_island_period ? 3'd3 : video_guard ? 3'd2 : video_data_period ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {{1'b0, data_island_preamble}, {1'b0, video_preamble || data_island_preamble}, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
                data_island_data[11:4] <= packet_data[8:1];
                data_island_data[3] <= cx != 0;
                data_island_data[2] <= packet_data[0];
                data_island_data[1:0] <= {vsync, hsync};
            end
        end
    end
    else // DVI_OUTPUT = 1
    begin
        always_ff @(posedge clk_pixel)
        begin
            if (reset)
            begin
                mode <= 3'd0;
                video_data <= 24'd0;
                control_data <= 6'd0;
            end
            else
            begin
                mode <= video_data_period ? 3'd1 : 3'd0;
                video_data <= rgb;
                control_data <= {4'b0000, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
            end
        end
    end
endgenerate

// All logic below relates to the production and output of the 10-bit TMDS code.
logic [9:0] tmds_internal [NUM_CHANNELS-1:0] /* verilator public_flat */ ;
genvar i;
generate
    // TMDS code production.
    for (i = 0; i < NUM_CHANNELS; i++)
    begin: tmds_gen
        tmds_channel #(.CN(i)) tmds_channel (.clk_pixel(clk_pixel), .video_data(video_data[i*8+7:i*8]), .data_island_data(data_island_data[i*4+3:i*4]), .control_data(control_data[i*2+1:i*2]), .mode(mode), .tmds(tmds_internal[i]));
    end
endgenerate

serializer #(.NUM_CHANNELS(NUM_CHANNELS)) serializer(.clk_pixel(clk_pixel), .clk_pixel_x5(clk_pixel_x5), .reset(reset), .tmds_internal(tmds_internal), .tmds(tmds), .tmds_clock(tmds_clock));

endmodule
