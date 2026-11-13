`timescale 1ns / 1ps

module max7219_hex_driver #(
    parameter int SYS_CLK_FRQ = 50_000_000 // Частота тактування системи (50 МГц)
)(
    input  logic        clk,          // Вхідна тактова частота системи 50 МГц
    input  logic        reset_n,      // Сигнал скидання (активний низький)
    
    // Інтерфейс даних від вашого модуля-моста (4 BCD тетради)
    input  logic [15:0] adc_data,     // Структура пакета: [15:12]=Volt, [11:8]=Hund, [7:4]=Tens, [3:0]=Units
    input  logic        data_valid,   // Строб готовності даних від АЦП/моста
    input  logic        i2c_ack_err,  // Прапорець апаратної помилки I2C
    
    // Фізичні виходи SPI на модуль MAX7219
    output logic        max_cs,       // Вихід Latch / CS
    output logic        max_clk,      // Вихід SPI Clock
    output logic        max_din       // Вихід SPI Data
);

    // =========================================================================
    // 1. ОГОЛОШЕННЯ ТИПІВ ДАННИХ ТА СИГНАЛІВ
    // =========================================================================
    typedef enum logic [3:0] {
        init_1, init_2, init_3, init_4, init_5, 
        idle_wait, read_data,
        dig_3, dig_2, dig_1, dig_0
    } state_t;

    typedef enum logic [2:0] {
        idle, start, clk_data, clk_high, clk_low, finished
    } driver_state_t;

    state_t        state;
    driver_state_t driver_state;
    
    logic [15:0] command;
    
    // 4 байта пам'яті для зберігання масок сегментів
    logic [7:0]  dig3_data, dig2_data, dig1_data, dig0_data;
    
    int counter;
    int clk_counter;

    // =========================================================================
    // 2. ЗНАКОГЕНЕРАТОР З РОЗВОРУТОМ НА 180 ГРАДУСІВ (Common Cathode)
    // Звичайні біти сегментів: DP-A-B-C-D-E-F-G (або подібні у вашій платі)
    // Перераховано комбінаторику ліній під фізичний переворот матриці індикатора
    // =========================================================================
    function automatic logic [7:0] num2seg_rot180 (input logic [3:0] num);
        case (num)
            4'h0: return 8'b01111110; // "0"
            4'h1: return 8'b00000110; // "1" (зміщено на протилежні сегменти)
            4'h2: return 8'b01101101; // "2"
            4'h3: return 8'b01111001; // "3"
            4'h4: return 8'b00110011; // "4"
            4'h5: return 8'b01011011; // "5"
            4'h6: return 8'b01011111; // "6"
            4'h7: return 8'b01110000; // "7"
            4'h8: return 8'b01111111; // "8"
            4'h9: return 8'b01111011; // "9"
            default: return 8'b00000000;
        endcase
    endfunction
    // =========================================================================
    // 3. ОСНОВНИЙ СИНХРОННИЙ АВТОМАТ ОБРОБКИ ТА ВИДАЧІ ДАНИХ
    // =========================================================================
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state        <= init_1;
            driver_state <= idle;
            command      <= 16'h0000;
            dig3_data    <= 8'h00;
            dig2_data    <= 8'h00;
            dig1_data    <= 8'h00;
            dig0_data    <= 8'h00;
            counter      <= 0;
            clk_counter  <= 0;
            max_cs       <= 1'b1;
            max_clk      <= 1'b0;
            max_din      <= 1'b0;
        end else begin
            
            case (state)
                init_1: begin
                    if (driver_state == idle) begin
                        command      <= 16'h0f00; // Вимкнення Display Test
                        driver_state <= start;
                        state        <= init_2;
                    end
                end
                init_2: begin
                    if (driver_state == idle) begin
                        command      <= 16'h0c01; // Shutdown / Normal operation
                        driver_state <= start;
                        state        <= init_3;
                    end
                end
                init_3: begin
                    if (driver_state == idle) begin
                        command      <= 16'h0900; // Decode mode: No decode
                        driver_state <= start;
                        state        <= init_4;
                    end
                end
                init_4: begin
                    if (driver_state == idle) begin
                        command      <= 16'h0A02; // Intensity: Середня яскравість
                        driver_state <= start;
                        state        <= init_5;
                    end
                end
                init_5: begin
                    if (driver_state == idle) begin
                        command      <= 16'h0B03; // Scan limit: 4 знаки (0, 1, 2, 3)
                        driver_state <= start;
                        state        <= idle_wait;
                    end
                end

                idle_wait: begin
                    if (data_valid) begin
                        state <= read_data;
                    end
                end

                read_data: begin
                    if (i2c_ack_err) begin
                        // Аварійний режим I2C з урахуванням перевороту індикатора
                        dig3_data <= 8'b00000101; // "r"
                        dig2_data <= 8'b00000101; // "r"
                        dig1_data <= 8'b01001111; // "E"
                        dig0_data <= 8'b00000000; // Порожньо
                    end else begin
                        // НАЛАШТУВАННЯ ПІД ПОВНИЙ РОЗВОРУТ НА 180° ТА ПРАВИЛЬНУ ПОЗИЦІЮ КОМИ:
                        // При фізичному перевороті плати ліва та права цифри міняються місцями автоматично.
                        // Оскільки ваша плата була дзеркальною, то подвійний розворот (дзеркало плати + переворот заліза) 
                        // повертає нас до ПРЯМОГО сортування індикаторів!
                        
                        // Запитувана кома після першої цифри (Цілі Вольти):
                        // Прив'язуємо її до розряду Вольт через побітове АБО з кодом крапки (8'b10000000)
                        dig3_data <= num2seg_rot180(adc_data[3:0]);                 // Младший розряд (Тисячні)
                        dig2_data <= num2seg_rot180(adc_data[7:4]);                 // Середній розряд  (Сотні)
                        dig1_data <= num2seg_rot180(adc_data[11:8]);                // Старший розряд   (Десяті)
                        dig0_data <= num2seg_rot180(adc_data[15:12]) | 8'b10000000; // Найперший знак     (Вольти.)
                    end
                    state <= dig_3;
                end

                // Послідовно оновлюємо всі 4 фізичні регістри індикаторів MAX7219
                dig_3: begin
                    if (driver_state == idle) begin
                        command      <= {8'h01, dig3_data}; // Запис у перший індикатор (Digit 1)
                        driver_state <= start;
                        state        <= dig_2;
                    end
                end
                dig_2: begin
                    if (driver_state == idle) begin
                        command      <= {8'h02, dig2_data}; // Другий індикатор (Digit 2)
                        driver_state <= start;
                        state        <= dig_1;
                    end
                end
                dig_1: begin
                    if (driver_state == idle) begin
                        command      <= {8'h03, dig1_data}; // Третій індикатор (Digit 3)
                        driver_state <= start;
                        state        <= dig_0;
                    end
                end
                dig_0: begin
                    if (driver_state == idle) begin
                        command      <= {8'h04, dig0_data}; // Четвертий індикатор (Digit 4)
                        driver_state <= start;
                        state        <= idle_wait;          
                    end
                end
                default: state <= init_1;
            endcase

            // =========================================================================
            // 4. ВАШ SPI ДРАЙВЕР НИЖНЬОГО РІВНЯ (БЕЗ ЗМІН)
            // =========================================================================
            if (clk_counter < 100) begin
                clk_counter <= clk_counter + 1;
            end else begin
                clk_counter <= 0;
                
                case (driver_state)
                    idle: begin
                        max_cs  <= 1'b1;
                        max_clk <= 1'b0;
                    end
                    start: begin
                        max_cs       <= 1'b0;
                        counter      <= 16;
                        driver_state <= clk_data;
                    end
                    clk_data: begin
                        counter      <= counter - 1;
                        max_din      <= command[counter - 1]; 
                        driver_state <= clk_high;
                    end
                    clk_high: begin
                        max_clk      <= 1'b1;
                        driver_state <= clk_low;
                    end
                    clk_low: begin
                        max_clk <= 1'b0;
                        if (counter == 0) begin
                            max_cs       <= 1'b1;
                            driver_state <= finished;
                        end else begin
                            driver_state <= clk_data;
                        end
                    end
                    finished: begin
                        driver_state <= idle;
                    end
                    default: driver_state <= idle;
                endcase
            end
        end
    end

endmodule
