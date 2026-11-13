`timescale 1ns / 1ps

module bin_to_bcd_3300 (
    input  logic        clk,
    input  logic        reset_n,
    input  logic [11:0] bin_val,     // Число мілівольт (0..3300)
    input  logic        start,       
    output logic [3:0]  bcd3,        // Цілі Вольти
    output logic [3:0]  bcd2,        // Десяті
    output logic [3:0]  bcd1,        // Соті
    output logic [3:0]  bcd0,        // Тисячні
    output logic        ready        
);

    typedef enum logic [1:0] {ST_IDLE, ST_SHIFT, ST_DONE} t_state;
    t_state state;

    logic [11:0] shift_reg;
    logic [15:0] bcd_reg;
    int bit_cnt;

    assign bcd3 = bcd_reg[15:12];
    assign bcd2 = bcd_reg[11:8];
    assign bcd1 = bcd_reg[7:4];
    assign bcd0 = bcd_reg[3:0];

    logic [3:0] corrected_bcd3, corrected_bcd2, corrected_bcd1, corrected_bcd0;

    always_comb begin
        corrected_bcd3 = (bcd_reg[15:12] >= 5) ? bcd_reg[15:12] + 4'd3 : bcd_reg[15:12];
        corrected_bcd2 = (bcd_reg[11:8]  >= 5) ? bcd_reg[11:8]  + 4'd3 : bcd_reg[11:8];
        corrected_bcd1 = (bcd_reg[7:4]   >= 5) ? bcd_reg[7:4]   + 4'd3 : bcd_reg[7:4];
        corrected_bcd0 = (bcd_reg[3:0]   >= 5) ? bcd_reg[3:0]   + 4'd3 : bcd_reg[3:0];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state     <= ST_IDLE;
            bcd_reg   <= '0;
            shift_reg <= '0;
            bit_cnt   <= 0;
            ready     <= 1'b0;
        end else begin
            ready <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        shift_reg <= bin_val;
                        bcd_reg   <= '0;
                        bit_cnt   <= 12; 
                        state     <= ST_SHIFT;
                    end
                end

                ST_SHIFT: begin
                    if (bit_cnt > 0) begin
                        bcd_reg   <= {corrected_bcd3[2:0], corrected_bcd2[3:0], corrected_bcd1[3:0], corrected_bcd0[3:0], shift_reg[11]};
                        shift_reg <= {shift_reg[10:0], 1'b0};
                        bit_cnt   <= bit_cnt - 1;
                    end else begin
                        state <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    ready <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
