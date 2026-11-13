`timescale 1ns / 1ps

module adc_processing_bridge (
    input  logic        clk,
    input  logic        reset_n,
    
    // Вхідний інтерфейс від автомата опитування АЦП
    input  logic [15:0] s_adc_data,
    input  logic        s_data_valid,
    input  logic        s_i2c_ack_err,
    
    // Модифікований вихідний інтерфейс для вашого 4-розрядного драйвера
    output logic [15:0] m_adc_data,
    output logic        m_data_valid,
    output logic        m_i2c_ack_err
);

    logic [11:0] clean_adc_12bit;
    logic [11:0] voltage_mv;
    logic        bcd_start;
    logic        bcd_ready;
    
    logic [12:0] temp_mv; 
    logic [3:0]  bcd3_v, bcd2_h, bcd1_t, bcd0_m;

    // Керуючий автомат координації обчислень
    typedef enum logic [1:0] {ST_WAIT_ADC, ST_START_BCD, ST_WAIT_BCD, ST_OUT} t_bridge_state;
    t_bridge_state state;

    // Приєднуємо ваш послідовний BCD конвертер
    bin_to_bcd_3300 u_bcd_calc (
        .clk     (clk),
        .reset_n (reset_n),
        .bin_val (voltage_mv),
        .start   (bcd_start),
        .bcd3    (bcd3_v),  // Цілі Вольти
        .bcd2    (bcd2_h),  // Десяті
        .bcd1    (bcd1_t),  // Сотні
        .bcd0    (bcd0_m),  // Тисячні
        .ready   (bcd_ready)
    );

    // Прокидаємо прапорець помилки I2C транзитом
    assign m_i2c_ack_err = s_i2c_ack_err;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= ST_WAIT_ADC;
            voltage_mv   <= '0;
            temp_mv      <= '0;
            bcd_start    <= 1'b0;
            m_adc_data   <= '0;
            m_data_valid <= 1'b0;
        end else begin
            m_data_valid <= 1'b0;
            bcd_start    <= 1'b0;

            case (state)
                ST_WAIT_ADC: begin
                    if (s_data_valid) begin
                        
                        // ЗАХИСТ ВІД UNDERFLOW (ПЕРЕВІРКА СТАРШОГО ЗНАКОВОГО БІТА 15):
                        // Якщо 15-й біт дорівнює 1, це додатковий код негативного числа (наприклад, FFF0).
                        // В такому випадку примусово зануляємо мілівольти.
                        if (s_adc_data[15] == 1'b1) begin
                            voltage_mv <= 12'd0;
                        end else begin
                            // 1. Якщо число позитивне, прибираємо ліве вирівнювання ADS1015
                            clean_adc_12bit = s_adc_data >> 4;
                            
                            // 2. Розрахунок мілівольт: Код АЦП * 2 мВ
                            temp_mv = {clean_adc_12bit, 1'b0}; 
                            
                            // 3. Обмежуємо верхню межу діапазоном живлення (3.3В = 3300 мВ)
                            if (temp_mv > 13'd3300) begin
                                voltage_mv <= 12'd3300;
                            end else begin
                                voltage_mv <= temp_mv[11:0];
                            end
                        end
                        state <= ST_START_BCD;
                    end
                end

                ST_START_BCD: begin
                    bcd_start <= 1'b1; // Запуск дешифратора Double Dabble
                    state     <= ST_WAIT_BCD;
                end

                ST_WAIT_BCD: begin
                    if (bcd_ready) begin
                        // 4. Пакування BCD для 4-розрядного перевернутого драйвера
                        m_adc_data[3:0]   <= bcd0_m; // Тисячні
                        m_adc_data[7:4]   <= bcd1_t; // Сотні
                        m_adc_data[11:8]  <= bcd2_h; // Десяті
                        m_adc_data[15:12] <= bcd3_v; // Цілі Вольти
                        
                        state <= ST_OUT;
                    end
                end

                ST_OUT: begin
                    m_data_valid <= 1'b1; 
                    state        <= ST_WAIT_ADC;
                end
                default: state <= ST_WAIT_ADC;
            endcase
        end
    end
endmodule
