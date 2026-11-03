/**
 * ============================================================================
 * stm32_bh1750_test.c — BH1750 模块独立验证 (软件 I2C, 适配任意 STM32 + HAL 库)
 * ============================================================================
 * 用途: 绕开 ACG525, 用 STM32 独立验证 BH1750 模块本身的好坏与地址。
 *       若 STM32 也读回 FFFF 不变 → 模块测量引擎坏/假芯片, 换模块;
 *       若 STM32 读数正常随光强变化 → 问题在 ACG525 侧, 再回来找我。
 *
 * 使用步骤:
 *   1. 把下面 BH_SCL/BH_SDA 两个宏改成手头板子任意两个空闲 GPIO
 *      ( examples: F103 = PA8/PA9, F4 = PB6/PB7, 自行对应 )
 *   2. 模块 VCC 接 STM32 的 3.3V (勿 5V), GND 共地, SCL/SDA 对应连接
 *   3. main.c 里调用 bh1750_standalone_test(); 结果走 printf
 *      (printf 默认重定向到串口; 没配串口就把结果存到 volatile 数组里用调试器看)
 *
 * 判读标准:
 *   [SCAN] 打印总线上所有应答地址 —— 正常应只见 0x23 (ADDR=L) 或 0x5C (ADDR=H)
 *          若扫描出多个地址 / 其他地址 → 总线异常或挂了别的设备
 *   [BH1750] 发 0x10 (连续 H-res) 后每 300ms 读 2 字节:
 *          数值随光强变化 (遮挡骤降) → 模块 GOOD
 *          恒 0xFFFF 且遮挡不变    → 数字接口活着, 测量引擎坏 → 换模块
 *          完全无应答               → 接线/供电/模块数字部分坏
 * ============================================================================
 */
#include "main.h"            /* 换成你工程实际的 HAL 头, 如 stm32f1xx_hal.h */

/*---- 改这里: 任意两个 GPIO (建议 4.7k~10k 外部上拉, 或开内部上拉) ----*/
#define BH_SCL_PORT   GPIOA
#define BH_SCL_PIN    GPIO_PIN_8
#define BH_SDA_PORT   GPIOA
#define BH_SDA_PIN    GPIO_PIN_9
#define BH_I2C_HZ     100000

/*---- 开漏位操作: OD 模式下写 1 = 释放(靠上拉), 写 0 = 拉低 ----*/
#define SCL_H()  HAL_GPIO_WritePin(BH_SCL_PORT, BH_SCL_PIN, GPIO_PIN_SET)
#define SCL_L()  HAL_GPIO_WritePin(BH_SCL_PORT, BH_SCL_PIN, GPIO_PIN_RESET)
#define SDA_H()  HAL_GPIO_WritePin(BH_SDA_PORT, BH_SDA_PIN, GPIO_PIN_SET)
#define SDA_L()  HAL_GPIO_WritePin(BH_SDA_PORT, BH_SDA_PIN, GPIO_PIN_RESET)
#define SDA_RD() HAL_GPIO_ReadPin (BH_SDA_PORT, BH_SDA_PIN)

static void dwt_delay_init(void)
{
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT = 0;
    DWT->CTRL  |= DWT_CTRL_CYCCNTENA_Msk;
}

static void delay_us(uint32_t us)   /* 适用于 M3/M4/M7 (HSE 时钟已配好的 HAL 工程) */
{
    uint32_t start = DWT->CYCCNT;
    uint32_t ticks = us * (SystemCoreClock / 1000000U);
    while ((DWT->CYCCNT - start) < ticks) { __NOP(); }
}

static void i2c_halfbit(void) { delay_us(5000000U / BH_I2C_HZ / 4U); } /* 1/4 位 */

static void i2c_init(void)
{
    GPIO_InitTypeDef g = {0};
    __HAL_RCC_GPIOA_CLK_ENABLE();           /* 换端口时记得改时钟 */
    g.Mode = GPIO_MODE_OUTPUT_OD;           /* 开漏: 写 1 即释放 */
    g.Pull = GPIO_PULLUP;
    g.Speed = GPIO_SPEED_FREQ_LOW;
    g.Pin = BH_SCL_PIN;
    HAL_GPIO_Init(BH_SCL_PORT, &g);
    g.Pin = BH_SDA_PIN;
    HAL_GPIO_Init(BH_SDA_PORT, &g);
    SCL_H(); SDA_H();                       /* 空闲: 双高 */
    HAL_Delay(10);
    dwt_delay_init();
}

static void i2c_start(void)
{
    SDA_H(); SCL_H();  i2c_halfbit();
    SDA_L();          i2c_halfbit();        /* SCL 高时 SDA 下降 = START */
    SCL_L();          i2c_halfbit();
}

static void i2c_stop(void)
{
    SCL_L(); SDA_L(); i2c_halfbit();
    SCL_H();          i2c_halfbit();
    SDA_H();          i2c_halfbit();        /* SCL 高时 SDA 上升 = STOP */
}

/* 返回 0=从机 ACK, 1=NACK */
static int i2c_write_byte(uint8_t b)
{
    int i, nack;
    for (i = 0; i < 8; i++) {
        SCL_L();
        if (b & 0x80) SDA_H(); else SDA_L();
        i2c_halfbit();
        SCL_H();      i2c_halfbit();
        b <<= 1;
    }
    SCL_L(); SDA_H(); i2c_halfbit();        /* 释放, 等从机 ACK */
    SCL_H();          i2c_halfbit();
    nack = (SDA_RD() == GPIO_PIN_SET);
    SCL_L();          i2c_halfbit();
    return nack;
}

static uint8_t i2c_read_byte(int ack)       /* ack=1 主机回 ACK, 0=回 NACK */
{
    int i;
    uint8_t v = 0;
    SDA_H();                                /* 释放总线 */
    for (i = 0; i < 8; i++) {
        SCL_L();      i2c_halfbit();
        SCL_H();      i2c_halfbit();
        v = (uint8_t)((v << 1) | (SDA_RD() == GPIO_PIN_SET));
    }
    SCL_L();
    if (ack) SDA_L(); else SDA_H();
    i2c_halfbit();
    SCL_H();          i2c_halfbit();
    SCL_L(); SDA_H(); i2c_halfbit();
    return v;
}

/*---- I2C Scanner: 扫 7 位地址空间, 打印所有应答设备 ----*/
void i2c_scan(void)
{
    uint8_t a;
    printf("[SCAN] responding addresses:\r\n");
    for (a = 0x08; a <= 0x77; a++) {
        i2c_start();
        if (i2c_write_byte((uint8_t)(a << 1)) == 0)   /* 写方向探测 */
            printf("  0x%02X  (7-bit 0x%02X)\r\n", a << 1, a);
        i2c_stop();
    }
    printf("[SCAN] done\r\n");
}

/*---- BH1750 读数循环: 命令 -> 等 180ms -> 读 2 字节, 永久循环 ----*/
void bh1750_read_loop(uint8_t addr7)
{
    uint8_t w = (uint8_t)(addr7 << 1);
    uint8_t r = (uint8_t)((addr7 << 1) | 1);
    uint16_t raw;
    uint32_t t = 0;

    /* 发测量命令: 连续 H 分辨率 0x10 (1 lx/bit, 120ms) */
    i2c_start();
    i2c_write_byte(w);
    i2c_write_byte(0x10);
    i2c_stop();
    HAL_Delay(200);

    while (1) {
        /* 周期性重发命令, 保证测量不中断 */
        if ((t % 5) == 0) {
            i2c_start(); i2c_write_byte(w); i2c_write_byte(0x10); i2c_stop();
            HAL_Delay(200);
        }
        /* 读 2 字节 */
        i2c_start(); i2c_write_byte(w); i2c_stop();
        i2c_start(); i2c_write_byte(r);
        raw = (uint16_t)((i2c_read_byte(1) << 8) | i2c_read_byte(0));
        i2c_stop();
        printf("[0x%02X] t=%lus raw=0x%04hX lux=%u\r\n",
               addr7, (unsigned long)(t++), (unsigned short)raw,
               (unsigned)(raw));                /* 0x10 模式: lux = 原始值 */
        HAL_Delay(300);
    }
}

/*---- 一键流程: 扫描 -> 对 0x23/0x5C 做读数验证 ----*/
void bh1750_standalone_test(void)
{
    i2c_init();
    i2c_scan();
    /* 先试 0x23 (ADDR=L), 无应答再试 0x5C (ADDR=H) */
    i2c_start();
    if (i2c_write_byte(0x23 << 1) == 0) { i2c_stop(); bh1750_read_loop(0x23); return; }
    i2c_stop();
    i2c_start();
    if (i2c_write_byte(0x5C << 1) == 0) { i2c_stop(); bh1750_read_loop(0x5C); return; }
    i2c_stop();
    printf("[BH1750] no response at 0x23/0x5C, check wiring/power!\r\n");
}

/* ============================================================================
 * 排错速查:
 *   扫描无任何应答   → 共地? VCC=3.3V? 上拉? SCL/SDA 接反?
 *   应答但恒 0xFFFF  → 遮挡测试不变 → 模块测量引擎坏, 换模块
 *   数值正常变化     → 模块 GOOD, 问题在 ACG525 侧 → 回来找小a
 * ============================================================================
 */
