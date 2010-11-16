module packet_router
    #(parameter BUF_SIZE = 9)
    (
        //wishbone interface for memory mapped CPU frames
        input wb_clk_i,
        input wb_rst_i,
        input wb_we_i,
        input wb_stb_i,
        input [15:0] wb_adr_i,
        input [31:0] wb_dat_i,
        output [31:0] wb_dat_o,
        output reg wb_ack_o,
        output wb_err_o,
        output wb_rty_o,

        input stream_clk,
        input stream_rst,

        //input control register
        input [31:0] control,

        //output status register
        output [31:0] status,

        output sys_int_o, //want an interrupt?

        // Input Interfaces (in to router)
        input [35:0] ser_inp_data, input ser_inp_valid, output ser_inp_ready,
        input [35:0] dsp_inp_data, input dsp_inp_valid, output dsp_inp_ready,
        input [35:0] eth_inp_data, input eth_inp_valid, output eth_inp_ready,

        // Output Interfaces (out of router)
        output [35:0] ser_out_data, output ser_out_valid, input ser_out_ready,
        output [35:0] dsp_out_data, output dsp_out_valid, input dsp_out_ready,
        output [35:0] eth_out_data, output eth_out_valid, input eth_out_ready
    );

    assign wb_err_o = 1'b0;  // Unused for now
    assign wb_rty_o = 1'b0;  // Unused for now
    always @(posedge wb_clk_i)
        wb_ack_o <= wb_stb_i & ~wb_ack_o;

    //which buffer: 0 = CPU read buffer, 1 = CPU write buffer
    wire which_buf = wb_adr_i[BUF_SIZE+2];

    ////////////////////////////////////////////////////////////////////
    // CPU interface to this packet router
    ////////////////////////////////////////////////////////////////////
    wire [35:0] cpu_inp_data;
    wire        cpu_inp_valid;
    wire        cpu_inp_ready;
    wire [35:0] cpu_out_data;
    wire        cpu_out_valid;
    wire        cpu_out_ready;

    ////////////////////////////////////////////////////////////////////
    // Communication interfaces
    ////////////////////////////////////////////////////////////////////
    wire [35:0] com_inp_data;
    wire        com_inp_valid;
    wire        com_inp_ready;
    wire [35:0] com_out_data;
    wire        com_out_valid;
    wire        com_out_ready;

    ////////////////////////////////////////////////////////////////////
    // status and control handshakes
    ////////////////////////////////////////////////////////////////////
    wire cpu_inp_hs_ctrl = control[0];
    wire cpu_out_hs_ctrl = control[1];
    wire [BUF_SIZE-1:0] cpu_out_line_count = control[BUF_SIZE-1+16:0+16];

    wire cpu_inp_hs_stat;
    assign status[0] = cpu_inp_hs_stat;

    wire [BUF_SIZE-1:0] cpu_inp_line_count;
    assign status[BUF_SIZE-1+16:0+16] = cpu_inp_line_count;

    wire cpu_out_hs_stat;
    assign status[1] = cpu_out_hs_stat;

    ////////////////////////////////////////////////////////////////////
    // Communication input source combiner
    //   - combine streams from serdes and ethernet
    ////////////////////////////////////////////////////////////////////
    fifo36_mux com_input_source(
        .clk(stream_clk), .reset(stream_rst), .clear(1'b0),
        .data0_i(eth_inp_data), .src0_rdy_i(eth_inp_valid), .dst0_rdy_o(eth_inp_ready),
        .data1_i(ser_inp_data), .src1_rdy_i(ser_inp_valid), .dst1_rdy_o(ser_inp_ready),
        .data_o(com_inp_data), .src_rdy_o(com_inp_valid), .dst_rdy_i(com_inp_ready)
    );

    ////////////////////////////////////////////////////////////////////
    // Communication output sink demuxer
    //   - demux the stream to serdes or ethernet
    ////////////////////////////////////////////////////////////////////
    wire eth_link_is_up = 1'b1; //TODO should come from input or register

    //connect the ethernet output signals
    assign eth_out_data = com_out_data;
    assign eth_out_valid = com_out_valid;

    //connect the serdes output signals
    assign ser_out_data = com_out_data;
    assign ser_out_valid = com_out_valid;

    //mux the com signal from the ethernet link
    assign com_out_ready = (eth_link_is_up)? eth_out_ready : ser_out_ready;

    ////////////////////////////////////////////////////////////////////
    // Communication output source combiner
    //   - combine streams from dsp framer, com inspector, and cpu
    ////////////////////////////////////////////////////////////////////
    //TODO: just connect com output to cpu output for now
    assign com_out_data = cpu_out_data;
    assign com_out_valid = cpu_out_valid;
    assign cpu_out_ready = com_out_ready;

    ////////////////////////////////////////////////////////////////////
    // Interface CPU input interface to memory mapped wishbone
    ////////////////////////////////////////////////////////////////////
    localparam CPU_INP_STATE_WAIT_SOF = 0;
    localparam CPU_INP_STATE_WAIT_EOF = 1;
    localparam CPU_INP_STATE_WAIT_CTRL_HI = 2;
    localparam CPU_INP_STATE_WAIT_CTRL_LO = 3;

    reg [1:0] cpu_inp_state;
    reg [BUF_SIZE-1:0] cpu_inp_addr;
    assign cpu_inp_line_count = cpu_inp_addr;
    wire [BUF_SIZE-1:0] cpu_inp_addr_next = cpu_inp_addr + 1'b1;

    wire cpu_inp_reading = (
        cpu_inp_state == CPU_INP_STATE_WAIT_SOF ||
        cpu_inp_state == CPU_INP_STATE_WAIT_EOF
    )? 1'b1 : 1'b0;

    wire cpu_inp_we = cpu_inp_reading;
    assign cpu_inp_ready = cpu_inp_reading;
    assign cpu_inp_hs_stat = (cpu_inp_state == CPU_INP_STATE_WAIT_CTRL_HI)? 1'b1 : 1'b0;

    RAMB16_S36_S36 cpu_inp_buff(
        //port A = wishbone memory mapped address space (output only)
        .DOA(wb_dat_o),.ADDRA(wb_adr_i[BUF_SIZE+1:2]),.CLKA(wb_clk_i),.DIA(36'b0),.DIPA(4'h0),
        .ENA(wb_stb_i & (which_buf == 1'b0)),.SSRA(0),.WEA(wb_we_i),
        //port B = packet router interface to CPU (input only)
        .DOB(),.ADDRB(cpu_inp_addr),.CLKB(stream_clk),.DIB(cpu_inp_data),.DIPB(4'h0),
        .ENB(cpu_inp_we),.SSRB(0),.WEB(cpu_inp_we)
    );

    always @(posedge stream_clk)
    if(stream_rst) begin
        cpu_inp_state <= CPU_INP_STATE_WAIT_SOF;
        cpu_inp_addr <= 0;
    end
    else begin
        case(cpu_inp_state)
        CPU_INP_STATE_WAIT_SOF: begin
            if (cpu_inp_ready & cpu_inp_valid & (cpu_inp_data[32] == 1'b1)) begin
                cpu_inp_state <= CPU_INP_STATE_WAIT_EOF;
                cpu_inp_addr <= cpu_inp_addr_next;
            end
        end

        CPU_INP_STATE_WAIT_EOF: begin
            if (cpu_inp_ready & cpu_inp_valid & (cpu_inp_data[33] == 1'b1)) begin
                cpu_inp_state <= CPU_INP_STATE_WAIT_CTRL_HI;
            end
            if (cpu_inp_ready & cpu_inp_valid) begin
                cpu_inp_addr <= cpu_inp_addr_next;
            end
        end

        CPU_INP_STATE_WAIT_CTRL_HI: begin
            if (cpu_inp_hs_ctrl == 1'b1) begin
                cpu_inp_state <= CPU_INP_STATE_WAIT_CTRL_LO;
            end
        end

        CPU_INP_STATE_WAIT_CTRL_LO: begin
            if (cpu_inp_hs_ctrl == 1'b0) begin
                cpu_inp_state <= CPU_INP_STATE_WAIT_SOF;
            end
            cpu_inp_addr <= 0; //reset the address counter
        end

        endcase //cpu_inp_state
    end

    ////////////////////////////////////////////////////////////////////
    // Interface CPU output interface to memory mapped wishbone
    ////////////////////////////////////////////////////////////////////
    localparam CPU_OUT_STATE_WAIT_CTRL_HI = 0;
    localparam CPU_OUT_STATE_WAIT_CTRL_LO = 1;
    localparam CPU_OUT_STATE_UNLOAD = 2;

    reg [1:0] cpu_out_state;
    reg [BUF_SIZE-1:0] cpu_out_addr;
    wire [BUF_SIZE-1:0] cpu_out_addr_next = cpu_out_addr + 1'b1;

    reg [BUF_SIZE-1:0] cpu_out_line_count_reg;

    reg cpu_out_flag_sof;
    reg cpu_out_flag_eof;
    assign cpu_out_data[35:32] = {2'b0, cpu_out_flag_eof, cpu_out_flag_sof};

    assign cpu_out_valid = (cpu_out_state == CPU_OUT_STATE_UNLOAD)? 1'b1 : 1'b0;
    assign cpu_out_hs_stat = (cpu_out_state == CPU_OUT_STATE_WAIT_CTRL_HI)? 1'b1 : 1'b0;

    RAMB16_S36_S36 cpu_out_buff(
        //port A = wishbone memory mapped address space (input only)
        .DOA(),.ADDRA(wb_adr_i[BUF_SIZE+1:2]),.CLKA(wb_clk_i),.DIA(wb_dat_i),.DIPA(4'h0),
        .ENA(wb_stb_i & (which_buf == 1'b1)),.SSRA(0),.WEA(wb_we_i),
        //port B = packet router interface from CPU (output only)
        .DOB(cpu_out_data[31:0]),.ADDRB(cpu_out_addr),.CLKB(stream_clk),.DIB(36'b0),.DIPB(4'h0),
        .ENB(1'b1),.SSRB(0),.WEB(1'b0)
    );

    always @(posedge stream_clk)
    if(stream_rst) begin
        cpu_out_state <= CPU_OUT_STATE_WAIT_CTRL_HI;
        cpu_out_addr <= 0;
    end
    else begin
        case(cpu_out_state)
        CPU_OUT_STATE_WAIT_CTRL_HI: begin
            if (cpu_out_hs_ctrl == 1'b1) begin
                cpu_out_state <= CPU_OUT_STATE_WAIT_CTRL_LO;
            end
            cpu_out_line_count_reg <= cpu_out_line_count;
            cpu_out_addr <= 0; //reset the address counter
        end

        CPU_OUT_STATE_WAIT_CTRL_LO: begin
            if (cpu_out_hs_ctrl == 1'b0) begin
                cpu_out_state <= CPU_OUT_STATE_UNLOAD;
                cpu_out_addr <= cpu_out_addr_next;
            end
            cpu_out_flag_sof <= 1'b1;
            cpu_out_flag_eof <= 1'b0;
        end

        CPU_OUT_STATE_UNLOAD: begin
            if (cpu_out_ready & cpu_out_valid) begin
                cpu_out_addr <= cpu_out_addr_next;
                cpu_out_flag_sof <= 1'b0;
                if (cpu_out_addr == cpu_out_line_count_reg) begin
                    cpu_out_flag_eof <= 1'b1;
                end
                else begin
                    cpu_out_flag_eof <= 1'b0;
                end
                if (cpu_out_flag_eof) begin
                    cpu_out_state <= CPU_OUT_STATE_WAIT_CTRL_HI;
                end
            end
        end

        endcase //cpu_out_state
    end

    ////////////////////////////////////////////////////////////////////
    // Communication input inspector
    //   - inspect com input and send it to CPU, DSP, or COM
    ////////////////////////////////////////////////////////////////////
    localparam COM_INSP_READ_COM_PRE = 0;
    localparam COM_INSP_READ_COM = 1;
    localparam COM_INSP_WRITE_DSP_REGS = 2;
    localparam COM_INSP_WRITE_DSP_LIVE = 3;
    localparam COM_INSP_WRITE_CPU_REGS = 4;
    localparam COM_INSP_WRITE_CPU_LIVE = 5;
    //FIXME collapse the write dsp/cpu states and use another register

    localparam COM_INSP_MAX_NUM_DREGS = 13; //padded_eth + ip + udp + vrt_hdr + extra cycle
    localparam COM_INSP_DREGS_DSP_OFFSET = 11; //offset to start dsp at

    reg [2:0] com_insp_state;
    reg [3:0] com_insp_dreg_count; //data registers to buffer headers
    wire [3:0] com_insp_dreg_count_next = com_insp_dreg_count + 1'b1;
    reg [35:0] com_insp_dregs [COM_INSP_MAX_NUM_DREGS-1:0];

    wire com_inp_dregs_is_data = 1'b1 //FIXME bit inspection is wrong (representation)
        & (com_insp_dregs[3][15:0] == 16'h800)    //ethertype IPv4
        & (com_insp_dregs[6][23:16] == 8'h11)     //protocol UDP
        & (com_insp_dregs[9][15:0] == 16'd49153)  //UDP data port
        & (com_insp_dregs[11][31:0] != 32'h0)     //VRT hdr non-zero
    ;

    /////////////////////////////////////
    //assign output signals to CPU input
    /////////////////////////////////////
    assign cpu_inp_data = (com_insp_state == COM_INSP_WRITE_CPU_REGS)?
        com_insp_dregs[com_insp_dreg_count] : com_inp_data
    ;
    assign cpu_inp_valid =
        (com_insp_state == COM_INSP_WRITE_CPU_REGS)? 1'b1          : (
        (com_insp_state == COM_INSP_WRITE_CPU_LIVE)? com_inp_valid : (
    1'b0));

    /////////////////////////////////////
    //assign output signals to DSP output
    /////////////////////////////////////
    wire [3:0] com_insp_dsp_flags = (com_insp_dreg_count == COM_INSP_DREGS_DSP_OFFSET)?
        4'b0001 : 4'b0000
    ;
    assign dsp_out_data = (com_insp_state == COM_INSP_WRITE_DSP_REGS)?
        {com_insp_dsp_flags, com_insp_dregs[com_insp_dreg_count][31:0]} : com_inp_data
    ;
    assign dsp_out_valid =
        (com_insp_state == COM_INSP_WRITE_DSP_REGS)? 1'b1          : (
        (com_insp_state == COM_INSP_WRITE_DSP_LIVE)? com_inp_valid : (
    1'b0));

    /////////////////////////////////////
    //assign output signal to COM input
    /////////////////////////////////////
    assign com_inp_ready =
        (com_insp_state == COM_INSP_READ_COM_PRE)  ? 1'b1          : (
        (com_insp_state == COM_INSP_READ_COM)      ? 1'b1          : (
        (com_insp_state == COM_INSP_WRITE_DSP_LIVE)? dsp_out_ready : (
        (com_insp_state == COM_INSP_WRITE_CPU_LIVE)? cpu_inp_ready : (
    1'b0))));

    always @(posedge stream_clk)
    if(stream_rst) begin
        com_insp_state <= COM_INSP_READ_COM_PRE;
        com_insp_dreg_count <= 0;
    end
    else begin
        case(com_insp_state)
        COM_INSP_READ_COM_PRE: begin
            if (com_inp_ready & com_inp_valid & com_inp_data[32]) begin
                com_insp_state <= COM_INSP_READ_COM;
                com_insp_dreg_count <= com_insp_dreg_count_next;
                com_insp_dregs[com_insp_dreg_count] <= com_inp_data;
            end
        end

        COM_INSP_READ_COM: begin
            if (com_inp_ready & com_inp_valid) begin
                com_insp_dregs[com_insp_dreg_count] <= com_inp_data;
                if (com_inp_dregs_is_data & (com_insp_dreg_count_next == COM_INSP_MAX_NUM_DREGS)) begin
                    com_insp_state <= COM_INSP_WRITE_DSP_REGS;
                    com_insp_dreg_count <= COM_INSP_DREGS_DSP_OFFSET;
                end
                else if (com_inp_data[33] | (com_insp_dreg_count_next == COM_INSP_MAX_NUM_DREGS)) begin
                    com_insp_state <= COM_INSP_WRITE_CPU_REGS;
                    com_insp_dreg_count <= 0;
                end
                else begin
                    com_insp_dreg_count <= com_insp_dreg_count_next;
                end
            end
        end

        COM_INSP_WRITE_DSP_REGS: begin
            if (dsp_out_ready & dsp_out_valid) begin
                com_insp_dreg_count <= com_insp_dreg_count_next;
                if (com_insp_dreg_count_next == COM_INSP_MAX_NUM_DREGS) begin
                    com_insp_state <= COM_INSP_WRITE_DSP_LIVE;
                    com_insp_dreg_count <= 0;
                end
            end

        end

        COM_INSP_WRITE_DSP_LIVE: begin
            if (dsp_out_ready & dsp_out_valid & com_inp_data[33]) begin
                com_insp_state <= COM_INSP_READ_COM_PRE;
            end
        end

        COM_INSP_WRITE_CPU_REGS: begin
            if (cpu_inp_ready & cpu_inp_valid) begin
                com_insp_dreg_count <= com_insp_dreg_count_next;
                if (cpu_inp_data[33]) begin
                    com_insp_state <= COM_INSP_READ_COM_PRE;
                    com_insp_dreg_count <= 0;
                end
                else if (com_insp_dreg_count_next == COM_INSP_MAX_NUM_DREGS) begin
                    com_insp_state <= COM_INSP_WRITE_CPU_LIVE;
                    com_insp_dreg_count <= 0;
                end
            end
        end

        COM_INSP_WRITE_CPU_LIVE: begin
            if (cpu_inp_ready & cpu_inp_valid & com_inp_data[33]) begin
                com_insp_state <= COM_INSP_READ_COM_PRE;
            end
        end

        endcase //com_insp_state
    end

endmodule // packet_router