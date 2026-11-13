`timescale 1ns / 1ps

module top_project (
    input  logic        clk_50mhz,    // Вхідний тактовий сигнал 50 МГц з плати
    input  logic        reset_n,      // Кнопка скидання (активний низький рівень)
    
    // Фізичні двонаправлені піни шини I2C для підключення ADS1015
    inout  wire         scl,
    inout  wire         sda,
    
    // Фізичні піни інтерфейсу SPI для модуля MAX7219
    output logic        max7219_cs,
    output logic        max7219_clk,
    output logic        max7219_din
);

    // =========================================================================
    // ГЕНЕРАТОР ВНУТРІШНЬОГО POWER-UP RESET (ЗАХИСТ СТАРТУ З FLASH)
    // =========================================================================
    logic [20:0] r_power_up_cnt = '0;
    logic        w_internal_reset_n = 1'b0;

    always_ff @(posedge clk_50mhz) begin
        if (r_power_up_cnt < 21'h1FFFFF) begin // Утримуємо скидання ~41 мс при старті
            r_power_up_cnt     <= r_power_up_cnt + 1;
            w_internal_reset_n <= 1'b0;
        end else begin
            w_internal_reset_n <= reset_n; // Далі працює звичайна кнопка на платі
        end
    end

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
    // 1. МОДУЛЬ ФІЗИЧНОГО РІВНЯ I2C MASTER (Scott Larson VHDL)
    // =========================================================================
    i2c_master #(
        .input_clk (50_000_000),  
        .bus_clk   (100_000)      
    ) u_i2c_master (
        .clk       (clk_50mhz), 
        .reset_n   (w_internal_reset_n), // Підключено внутрішнє скидання
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
        .reset_n     (w_internal_reset_n), // Підключено внутрішнє скидання
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
    // 2.2. БЛОК КАСКАДНОГО ЦИФРОВИГО ФІЛЬТРА (Середнє 64 -> Медіана 5)
    // =========================================================================
    cascade_filter u_cascade_filter (
        .clk          (clk_50mhz),
        .reset_n      (w_internal_reset_n), // КРИТИЧНО: Має бути внутрішнє довге скидання!
        .i_data_valid (w_adc_ready),          
        .i_data       (w_adc_val),            
        .o_data_valid (w_filtered_adc_ready), 
        .o_data       (w_filtered_adc_val)   
    );


    // =========================================================================
    // 2.5. ПРОМІЖНИЙ ОБЧИСЛЮВАЛЬНИЙ МІСТ (Керування Double Dabble)
    // =========================================================================
    adc_processing_bridge u_processing_bridge (
        .clk           (clk_50mhz),
        .reset_n       (w_internal_reset_n), // Підключено внутрішнє скидання
        
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
        .reset_n     (w_internal_reset_n), // Підключено внутрішнє скидання
        .adc_data    (w_processed_bcd),       
        .data_valid  (w_processed_ready),  
        .i2c_ack_err (w_processed_ack_err),    
        .max_cs      (max7219_cs),   
        .max_clk     (max7219_clk),  
        .max_din     (max7219_din)   
    );

endmodule
