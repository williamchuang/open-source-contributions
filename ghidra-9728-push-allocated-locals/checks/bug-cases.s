@ Source of the machine code in bug-cases.xml (ARM Thumb, little-endian).
@ Assembled with GNU binutils 2.42 for arm-none-eabi:
@   arm-none-eabi-as -mcpu=cortex-m3 bug-cases.s -o bug-cases.o
@   arm-none-eabi-ld -Ttext=0x10000 bug-cases.o -o bug-cases.elf
@   arm-none-eabi-objcopy -O binary bug-cases.elf bug-cases.bin
.syntax unified
.text
.thumb
.org 0
my_function: push {r7, lr}
 movs r0, #1
 str r0, [sp, #0]
 mov r0, sp
 bl some_function
 pop {r0, pc}
.org 0x100
my_function2: push {r2, r3, r7, lr}
 movs r0, #1
 str r0, [sp, #0]
 mov r0, sp
 add r1, sp, #4
 add r2, sp, #8
 bl some_function
 pop {r0, r1, r2, pc}
.org 0x200
my_function3: push {r5, r6, r7, lr}
 mov r0, sp
 bl some_function
 add sp, #0xc
 pop {pc}
 .org 0x300
framefunc: push {r7, lr}
 add r7, sp, #0
 bl some_function
 nop
 pop {r7, pc}
.org 0x1000
some_function: bx lr
