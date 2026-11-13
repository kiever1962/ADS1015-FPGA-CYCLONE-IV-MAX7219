`timescale 1ns / 1ps

module top_project (
    input  logic        clk_50mhz,    // Вхідний тактовий сигнал 50 МГц з плати
    input  logic        reset_n,      // Кнопка скидання (активний низький уровень)
    
    // Фізичні двонаправлені піни шини I2C для підключення ADS1015
    inout  wire         scl,
    inout  wire         sda,
    
    // Фізичні піни інтерфейсу SPI для модуля MAX7219
    output logic        max7219_cs,
    output logic        max7219_clk,
    output logic        max7219_din
);

    // =========================================================================
    // ГЕНЕРАТОР НАДІЙНОГО ВНУТРІШНЬОГО POWER-UP RESET
    // =========================================================================
    // Зсувний регістр ініціалізується нулями апаратно при старті.
    // Навіть якщо залізо вмикається у випадковому стані, послідовний зсув одиниць
    // через такт clk_50mhz забезпечує чистий і синхронний старт усіх блоків.
    logic [7:0] r_reset_reg = 8'h00; 
    logic       w_internal_reset_n;

    always_ff @(posedge clk_50mhz) begin
        // Зсуваємо одиниці, якщо фізична кнопка reset_n відпущена (дорівнює 1)
        r_reset_reg <= {r_reset_reg[6:0], reset_n};
    end
    
    // Скидання відпуститься (стане 1) тільки після заповнення всього регістру
    assign w_internal_reset_n = &r_reset_reg;

    // =========================================================================
    // ОГОЛОШЕННЯ ВНУТРІШНІХ ЛІНІЙ ЗВ'ЯЗКУ
    // =========================================================================
    logic        w_ena;
    logic [6:0]  w_addr;
    logic        w_rw;
    logic [7:0]  w_data_wr;
    logic        w_busy;
    logic [7:0]  w_data_rd;
    logic        w_ack_err;
    
    logic [15:0] w_adc_val;   
    logic        w_adc_ready;

    logic [15:0] w_filtered_adc_val;
    logic        w_filtered_adc_ready;

    logic [15:0] w_processed_bcd;
    logic        w_processed_ready;
    logic        w_processed_ack_err;
    // =========================================================================
    // 1. МОДУЛЬ ФІЗИЧНОГО РІВНЯ I2C MASTER (НАЗВА i2c_master_sv)
    // =========================================================================
    i2c_master_sv #(
        .input_clk (50_000_000),  
        .bus_clk   (400_000)      
    ) u_i2c_master (
        .clk       (clk_50mhz), 
        .reset_n   (w_internal_reset_n), // Надійне подовжене скидання
        .ena       (w_ena), 
        .addr      (w_addr), 
        .rw        (w_rw),
        .data_wr   (w_data_wr), 
        .busy      (w_busy), 
        .data_rd   (w_data_rd), 
        .ack_error (w_ack_err),
        .sda       (sda), 
        .scl       (scl)
    );

    // =========================================================================
    // 2. КІНЦЕВИЙ АВТОМАТ ПЕРІОДИЧНОГО ЦИКЛІЧНОГО ОПИТУВАННЯ АЦП
    // =========================================================================
    ads1015_poll #(
        .SYS_CLK_FRQ (50_000_000) 
    ) u_ads1015_poll (
        .clk         (clk_50mhz), 
        .reset_n     (w_internal_reset_n), 
        .adc_data    (w_adc_val),       
        .data_valid  (w_adc_ready),     
        .i2c_ena     (w_ena), 
        .i2c_addr    (w_addr), 
        .i2c_rw      (w_rw), 
        .i2c_data_wr (w_data_wr),
        .i2c_busy    (w_busy), 
        .i2c_data_rd (w_data_rd), 
        .i2c_ack_err (w_ack_err)
    );

    // =========================================================================
    // 2.2. БЛОК КАСКАДНОГО ЦИФРОВИГО ФІЛЬТРА
    // =========================================================================
    cascade_filter u_cascade_filter (
        .clk          (clk_50mhz),
        .reset_n      (w_internal_reset_n), 
        .i_data_valid (w_adc_ready),          
        .i_data       (w_adc_val),            
        .o_data_valid (w_filtered_adc_ready), 
        .o_data       (w_filtered_adc_val)   
    );

    // =========================================================================
    // 2.5. ПРОМІЖНИЙ ОБЧИСЛЮВАЛЬНИЙ МІСТ (Double Dabble)
    // =========================================================================
    adc_processing_bridge u_processing_bridge (
        .clk           (clk_50mhz),
        .reset_n       (w_internal_reset_n), 
        
        .s_adc_data    (w_filtered_adc_val),   
        .s_data_valid  (w_filtered_adc_ready),
        .s_i2c_ack_err (w_ack_err),           
        
        .m_adc_data    (w_processed_bcd),     
        .m_data_valid  (w_processed_ready),
        .m_i2c_ack_err (w_processed_ack_err) 
    );

    // =========================================================================
    // 3. ДРАЙВЕР ДИСПЛЕЯ MAX7219
    // =========================================================================
    max7219_hex_driver #(
        .SYS_CLK_FRQ (50_000_000) 
    ) u_max7219_driver (
        .clk         (clk_50mhz),
        .reset_n     (w_internal_reset_n), 
        .adc_data    (w_processed_bcd),       
        .data_valid  (w_processed_ready),  
        .i2c_ack_err (w_processed_ack_err),    
        .max_cs      (max7219_cs),   
        .max_clk     (max7219_clk),  
        .max_din     (max7219_din)   
    );

endmodule
