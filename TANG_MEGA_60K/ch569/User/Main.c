/********************************** (C) COPYRIGHT *******************************
* File Name          : Main.c
* Author             : WCH
* Version            : V1.0
* Date               : 2023/02/16
*
* Copyright (c) 2021 Nanjing Qinheng Microelectronics Co., Ltd.
* Attention: This software (modified or not) and binary are used for
* microcontroller manufactured by Nanjing Qinheng Microelectronics.
*******************************************************************************/

/* USB CDC OUT -> UART2 TX (PA3 / board HD3 / FPGA K22).
 * HSPI stays disabled because it shares the UART2 pins.
 * USB2 and USB3 enumeration remain the vendor implementation.
 */
#define FREQ_SYS 120000000
#include "CH56x_common.h"
#include "CH56x_usb30.h"
#include "cdc.h"

int main(void)
{
    SystemInit(FREQ_SYS);
    Delay_Init(FREQ_SYS);
    R8_HSPI_CTRL = 0;
    CDC_Uart_Init(115200);
    TMR2_TimerInit1();
    R32_USB_CONTROL = 0;
    PFIC_EnableIRQ(USBSS_IRQn);
    PFIC_EnableIRQ(LINK_IRQn);
    PFIC_EnableIRQ(TMR0_IRQn);
    R8_TMR0_INTER_EN = 1;
    TMR0_TimerInit(67000000);
    USB30D_init(ENABLE);
    while(1) CDC_Uart_Deal();
}
