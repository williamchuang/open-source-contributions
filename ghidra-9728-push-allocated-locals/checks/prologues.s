@ Source of the machine code in prologues.xml (ARM Thumb, little-endian).
@ Assembled with GNU binutils 2.42 for arm-none-eabi:
@   arm-none-eabi-as -mcpu=cortex-m3 prologues.s -o prologues.o
@   arm-none-eabi-ld -Ttext=0x20000 prologues.o -o prologues.elf
@   arm-none-eabi-objcopy -O binary prologues.elf prologues.bin
.syntax unified
.text
.thumb
.org 0
prologue1: push {r7, lr}
 sub sp, #8
 add r7, sp, #0
 str r0, [r7, #4]
 ldr r0, [r7, #4]
 adds r0, #1
 str r0, [r7, #4]
 adds r0, r7, #4
 bl some_function
 ldr r0, [r7, #4]
 adds r7, #8
 mov sp, r7
 pop {r7, pc}
.org 0x100
prologue2: push {r7, lr}
 add r7, sp, #0
 bl some_function
 nop
 pop {r7, pc}
.org 0x200
prologue3: push {r4, r5, lr}
 sub sp, #12
 mov r4, r0
 mov r0, sp
 bl some_function
 ldr r0, [sp]
 adds r0, r4
 add sp, #12
 pop {r4, r5, pc}
.org 0x300
prologue4: push {r4, lr}
 movs r4, r0
 bl some_function
 adds r0, r4
 pop {r4, pc}
.org 0x400
prologue5: push {r4, r5, r6, r7, lr}
 add r7, sp, #12
 sub sp, #20
 mov r4, r0
 add r0, sp, #4
 bl some_function
 ldr r0, [sp, #4]
 adds r0, r4
 add sp, #20
 pop {r4, r5, r6, r7, pc}
.org 0x1000
some_function: bx lr
