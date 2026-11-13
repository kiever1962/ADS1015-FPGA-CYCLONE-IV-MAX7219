`timescale 1ns / 1ps

module ads1015_poll #(
    parameter int SYS_CLK_FRQ = 50_000_000  
)(
    input  logic        clk,          
    input  logic        reset_n,      
    
    output logic [15:0] adc_data,     
    output logic        data_valid,   
    
    output logic        i2c_ena,      
    output logic [6:0]  i2c_addr,     
    output logic        i2c_rw,       
    output logic [7:0]  i2c_data_wr,  
    input  logic        i2c_busy,     
    input  logic [7:0]  i2c_data_rd,  
    input  logic        i2c_ack_err   
);

    localparam logic [6:0] ADS1015_I2C_ADDR = 7'h48;
    localparam logic [7:0] REG_POINTER_CONV   = 8'h00; 
    localparam logic [7:0] REG_POINTER_CONFIG = 8'h01; 

    localparam logic [7:0] CONFIG_MSB = 8'hD3; 
    localparam logic [7:0] CONFIG_LSB = 8'h84; 

    localparam int INIT_DELAY_CYCLES   = (SYS_CLK_FRQ / 500);  
    localparam int CONFIG_DELAY_CYCLES = (SYS_CLK_FRQ / 1000); 
    localparam int LOOP_PAUSE_CYCLES   = (SYS_CLK_FRQ / 50);   

    typedef enum logic [2:0] {
        ST_RESET,          
        ST_START_DELAY,    
        ST_CONFIGURE,      
        ST_CONF_DELAY,     
        ST_SET_PTR,        
        ST_GET_DATA,       
        ST_LOOP_PAUSE      
    } state_t;

    state_t state;

    logic busy_prev;
    int   sub_cnt;     
    int   pause_timer; 
    
    logic [7:0] msb_buffer; 

    logic i2c_busy_sync0, i2c_busy_sync1;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            i2c_busy_sync0 <= 1'b0;
            i2c_busy_sync1 <= 1'b0;
        end else begin
            i2c_busy_sync0 <= i2c_busy;
            i2c_busy_sync1 <= i2c_busy_sync0;
        end
    end

    wire busy_falling_edge = (busy_prev == 1'b1 && i2c_busy_sync1 == 1'b0);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= ST_RESET;
            i2c_ena      <= 1'b0;
            i2c_addr     <= 7'h00;
            i2c_rw       <= 1'b0;
            i2c_data_wr  <= 8'h00;
            adc_data     <= 16'h0000;
            data_valid   <= 1'b0;
            busy_prev    <= 1'b0;
            sub_cnt      <= 0; 
            pause_timer  <= 0;
            msb_buffer   <= 8'h00;
        end else begin
            data_valid <= 1'b0; 
            busy_prev  <= i2c_busy_sync1; 

            case (state)
                
                ST_RESET: begin
                    i2c_ena     <= 1'b0;
                    sub_cnt     <= 0; 
                    pause_timer <= 0;
                    state       <= ST_START_DELAY;
                end

                ST_START_DELAY: begin
                    if (pause_timer < INIT_DELAY_CYCLES) begin
                        pause_timer <= pause_timer + 1;
                    end else begin
                        pause_timer <= 0;
                        state       <= ST_CONFIGURE; 
                    end
                end

                ST_CONFIGURE: begin
                    case (sub_cnt)
                        0: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena     <= 1'b1;
                                i2c_addr    <= ADS1015_I2C_ADDR;
                                i2c_rw      <= 1'b0; 
                                i2c_data_wr <= REG_POINTER_CONFIG; 
                            end
                            if (i2c_busy_sync1) begin
                                i2c_ena <= 1'b0; 
                                sub_cnt <= 1;
                            end
                        end
                        
                        1: begin 
                            if (busy_falling_edge) begin
                                if (i2c_ack_err) state <= ST_RESET;
                                else             sub_cnt <= 2;
                            end
                        end

                        2: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena     <= 1'b1;
                                i2c_data_wr <= CONFIG_MSB;
                            end
                            if (i2c_busy_sync1) begin
                                i2c_ena <= 1'b0;
                                sub_cnt <= 3;
                            end
                        end

                        3: begin 
                            if (busy_falling_edge) begin
                                if (i2c_ack_err) state <= ST_RESET;
                                else             sub_cnt <= 4;
                            end
                        end

                        4: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena     <= 1'b1;
                                i2c_data_wr <= CONFIG_LSB;
                            end
                            if (i2c_busy_sync1) begin
                                i2c_ena <= 1'b0; 
                                sub_cnt <= 5;
                            end
                        end

                        5: begin 
                            if (busy_falling_edge) begin
                                pause_timer <= 0;
                                sub_cnt     <= 0;
                                state       <= ST_CONF_DELAY; 
                            end
                        end
                    endcase
                end

                ST_CONF_DELAY: begin
                    if (pause_timer < CONFIG_DELAY_CYCLES) begin
                        pause_timer <= pause_timer + 1;
                    end else begin
                        pause_timer <= 0;
                        state       <= ST_SET_PTR; 
                    end
                end

                ST_SET_PTR: begin
                    case (sub_cnt)
                        0: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena     <= 1'b1;
                                i2c_addr    <= ADS1015_I2C_ADDR;
                                i2c_rw      <= 1'b0; 
                                i2c_data_wr <= REG_POINTER_CONV; 
                            end
                            if (i2c_busy_sync1) begin
                                i2c_ena <= 1'b0; 
                                sub_cnt <= 1;
                            end
                        end

                        1: begin 
                            if (busy_falling_edge) begin
                                if (i2c_ack_err) begin
                                    state <= ST_RESET;
                                end else begin
                                    pause_timer <= 0;
                                    sub_cnt     <= 0;
                                    state       <= ST_GET_DATA; 
                                end
                            end
                        end
                    endcase
                end

                ST_GET_DATA: begin
                    case (sub_cnt)
                        0: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena  <= 1'b1;
                                i2c_addr <= ADS1015_I2C_ADDR;
                                i2c_rw   <= 1'b1; 
                            end
                            if (i2c_busy_sync1) begin
                                sub_cnt <= 1; 
                            end
                        end

                        1: begin 
                            if (busy_falling_edge) begin
                                if (i2c_ack_err) begin
                                    state <= ST_RESET;
                                end else begin
                                    msb_buffer <= i2c_data_rd; 
                                    sub_cnt    <= 2;
                                end
                            end
                        end

                        2: begin 
                            if (!i2c_busy_sync1 && !i2c_ena) begin
                                i2c_ena <= 1'b1; 
                            end
                            if (i2c_busy_sync1) begin
                                i2c_ena <= 1'b0; 
                                sub_cnt <= 3;
                            end
                        end

                        3: begin 
                            if (busy_falling_edge) begin
                                if (i2c_ack_err) begin
                                    state <= ST_RESET;
                                end else begin
                                    adc_data    <= {msb_buffer, i2c_data_rd}; 
                                    data_valid  <= 1'b1; 
                                    sub_cnt     <= 4;
                                end
                            end
                        end

                        4: begin 
                            pause_timer <= 0;
                            sub_cnt     <= 0;
                            state       <= ST_LOOP_PAUSE;
                        end
                    endcase
                end

                ST_LOOP_PAUSE: begin
                    i2c_ena <= 1'b0;
                    sub_cnt <= 0;
                    if (pause_timer < LOOP_PAUSE_CYCLES) begin
                        pause_timer <= pause_timer + 1;
                    end else begin
                        pause_timer <= 0;
                        state       <= ST_CONFIGURE; 
                    end
                end

                default: state <= ST_RESET;
            endcase
        end
    end

endmodule
