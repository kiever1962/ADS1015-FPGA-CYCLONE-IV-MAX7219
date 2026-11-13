`timescale 1ns / 1ps

// =========================================================================
// ГОЛОВНИЙ МОДУЛЬ КАСКАДНОГО ФІЛЬТРА (СЕРЕДНЄ 64 -> МЕДІАНА 5)
// =========================================================================
module cascade_filter (
    input  logic        clk,            // Частота системи 50 МГц
    input  logic        reset_n,        // Внутрішнє стабільне скидання w_internal_reset_n
    input  logic        i_data_valid,   // Строб готовності від ads1015_poll (w_adc_ready)
    input  logic [15:0] i_data,         // Сирі 16-бітні лівовирівняні дані АЦП (w_adc_val)
    output logic        o_data_valid,   // Новий строб готовності для вашого моста (w_filtered_adc_ready)
    output logic [15:0] o_data          // Очищені 16-бітні дані для вашого моста (w_filtered_adc_val)
);

    logic        w_avg_valid;
    logic [15:0] w_avg_data;

    // Крок 1: Скользяще середнє (64 елементи)
    moving_average_64 u_average (
        .clk          (clk),
        .reset_n      (reset_n), 
        .i_data_valid (i_data_valid),
        .i_data       (i_data),
        .o_data_valid (w_avg_valid),
        .o_average    (w_avg_data)
    );

    // Крок 2: Медіанний фільтр (5 елементів)
    median_filter_5 u_median (
        .clk          (clk),
        .reset_n      (reset_n), 
        .i_data_valid (w_avg_valid),   
        .i_data       (w_avg_data),    
        .o_data_valid (o_data_valid),  
        .o_median     (o_data)         
    );

endmodule


// =========================================================================
// 1. БЕЗЗНАКОВИЙ ФІЛЬТР СКОЛЬЗЯЩОГО СЕРЕДНЬОГО НА 64 ЕЛЕМЕНТИ
// =========================================================================
module moving_average_64 (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        i_data_valid,
    input  logic [15:0] i_data,
    output logic        o_data_valid,
    output logic [15:0] o_average
);

    localparam int N = 64;
    localparam int SHIFT = 6; 

    // Ініціалізація нулями під Flash старт
    logic [15:0] delay_line[0:N-1] = '{default: 16'd0};
    logic [21:0] sum = 22'd0; 

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sum          <= 22'd0;
            o_average    <= 16'd0;
            o_data_valid <= 1'b0;
            for (int i = 0; i < N; i++) begin
                delay_line[i] <= 16'd0;
            end
        end else begin
            o_data_valid <= 1'b0;

            if (i_data_valid) begin
                sum <= sum + i_data - delay_line[N-1];

                // Просування лінії затримки
                for (int i = N-1; i > 0; i--) begin
                    delay_line[i] <= delay_line[i-1];
                end
                delay_line[0] <= i_data; // ВИПРАВЛЕНО: Додано чіткий індекс розпакованого масиву

                o_average    <= (sum + i_data - delay_line[N-1]) >> SHIFT;
                o_data_valid <= 1'b1;
            end
        end
    end
endmodule


// =========================================================================
// 2. УЛТРА-ОПТИМІЗОВАНИЙ МЕДІАННИЙ ФІЛЬТР НА 5 ЕЛЕМЕНТІВ
// =========================================================================
module median_filter_5 (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        i_data_valid,
    input  logic [15:0] i_data,
    output logic        o_data_valid,
    output logic [15:0] o_median
);

    localparam int N = 5;
    localparam int MEDIAN_INDEX = 2; 

    logic [15:0] shift_reg[0:N-1] = '{default: 16'd0};
    logic [15:0] sorted[0:N-1] = '{default: 16'd0};
    
    logic [2:0]  rank_matrix[0:N-1] = '{default: 3'd0}; 
    logic        pipe_valid = 1'b0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            o_data_valid <= 1'b0;
            o_median     <= 16'd0;
            pipe_valid   <= 1'b0;
            for (int i = 0; i < N; i++) begin
                shift_reg[i]   <= 16'd0;
                sorted[i]      <= 16'd0;
                rank_matrix[i] <= 3'd0;
            end
        end else begin
            o_data_valid <= 1'b0;
            pipe_valid   <= 1'b0;

            // ТАКТ 1: Запис у малий зсувний регістр та швидкий розрахунок рангів
            if (i_data_valid) begin
                for (int i = N-1; i > 0; i--) begin
                    shift_reg[i] <= shift_reg[i-1];
                end
                shift_reg[0] <= i_data; // ВИПРАВЛЕНО: Додано чіткий індекс розпакованого масиву
                
                // Розрахунок рангів для 5 елементів
                for (int i = 0; i < N; i++) begin
                    logic [2:0] r;
                    r = 3'd0;
                    for (int j = 0; j < N; j++) begin
                        if (shift_reg[i] > shift_reg[j]) begin
                            r++;
                        end else if (shift_reg[i] == shift_reg[j] && i > j) begin
                            r++; 
                        end
                    end
                    rank_matrix[i] <= r;
                end
                pipe_valid <= 1'b1;
            end

            // ТАКТ 2: Розстановка по рангах та видача медіани
            if (pipe_valid) begin
                for (int i = 0; i < N; i++) begin
                    sorted[rank_matrix[i]] <= shift_reg[i];
                end
                o_median     <= sorted[MEDIAN_INDEX]; 
                o_data_valid <= 1'b1;
            end
        end
    end
endmodule
