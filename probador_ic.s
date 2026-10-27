// ============================================================================
//  Ensamblar y correr en QEMU:
//    aarch64-linux-gnu-as probador_ic.s -o probador_ic.o
//    aarch64-linux-gnu-ld probador_ic.o -o probador_ic
//    qemu-aarch64 ./probador_ic
// ============================================================================
 
// ------------------------- Datos de solo lectura ----------------------------
.section .rodata
 
msg_prompt: .ascii "ingrese el tipo de compuerta, solo los ultimos dos digitos \n"
.equ len_prompt, . - msg_prompt
 
msg_ok:     .ascii "IC. OK\n"
.equ len_ok, . - msg_ok
 
msg_mal:    .ascii "IC MAL\n"
.equ len_mal, . - msg_mal
 
msg_comp1:  .ascii "COMPUERTA "
.equ len_comp1, . - msg_comp1
 
msg_comp2:  .ascii " DANADA\n"
.equ len_comp2, . - msg_comp2
 
msg_inval:  .ascii "tipo invalido, intente de nuevo\n"
.equ len_inval, . - msg_inval
 
// Tablas de compuertas. Cada compuerta ocupa 4 bytes:

.align 2
gates2:                      // 7400 / 7408 / 7432 : 4 compuertas de 2 entradas
    .byte 11, 10, 0xFF,  9   // G1: pin1,pin2 -> pin3
    .byte  8,  7, 0xFF,  6   // G2: pin4,pin5 -> pin6
    .byte  4,  3, 0xFF,  5   // G3: pin9,pin10 -> pin8
    .byte  1,  0, 0xFF,  2   // G4: pin12,pin13 -> pin11
 
gates3:                      // 7427 : 3 compuertas de 3 entradas (NOR)
    .byte 11, 10,  1,  0     // G1: pin1,pin2,pin12 -> pin13
    .byte  9,  8,  7,  6     // G2: pin3,pin4,pin5 -> pin6
    .byte  4,  3,  2,  5     // G3: pin9,pin10,pin11 -> pin8
 
// ------------------------------- Datos --------------------------------------
.section .data
.align 3
timespec:  .quad 0           // tv_sec  = 0
           .quad 10000000    // tv_nsec = 10 ms
 
// --------------------------- Memoria sin init -------------------------------
.section .bss
.align 3
buf:    .skip 8              // buffer de teclado
digito: .skip 1              // caracter con el numero de compuerta 
 
// ------------------------------- Codigo -------------------------------------
.text
.global _start
 
// Contexto que se mantiene durante toda una prueba 
//   x19 = puntero a la tabla de compuertas
//   x20 = cantidad de compuertas
//   x21 = cantidad de entradas por compuerta (2 o 3)
//   x22 = operacion logica:  0=NAND  1=AND  2=NOR  3=OR
 
_start:
main_loop:
    // ---- 1) Enviar el mensaje de solicitud -----------------------------
    ldr  x1, =msg_prompt
    mov  x2, #len_prompt
    bl   puts
 
    // ---- 2) Monitorear el teclado (lee la linea: 2 digitos + enter) ----
    mov  x0, #0              // fd = stdin
    ldr  x1, =buf
    mov  x2, #8
    mov  x8, #63             // syscall read
    svc  #0
    cmp  x0, #2              // si llegaron menos de 2 bytes, repetir
    b.lt main_loop
 
    // ---- Convertir los dos digitos ASCII a un numero -------------------
    ldr  x3, =buf
    ldrb w4, [x3]            // primer digito
    ldrb w5, [x3, #1]        // segundo digito
    sub  w4, w4, #48         // '0' = 48  -> a valor numerico
    sub  w5, w5, #48
    mov  w6, #10
    mul  w4, w4, w6
    add  w4, w4, w5          // w4 = valor (0, 8, 27 o 32)
 
    // ---- 3) Seleccionar el IC: configura x19..x22 ----------------------
    cmp  w4, #0
    b.eq ic_7400
    cmp  w4, #8
    b.eq ic_7408
    cmp  w4, #27
    b.eq ic_7427
    cmp  w4, #32
    b.eq ic_7432
 
    ldr  x1, =msg_inval      // tipo no valido -> avisar y volver
    mov  x2, #len_inval
    bl   puts
    b    main_loop
 
ic_7400:                     // NAND
    ldr  x19, =gates2
    mov  x20, #4
    mov  x21, #2
    mov  x22, #0
    b    run_test
ic_7408:                     // AND
    ldr  x19, =gates2
    mov  x20, #4
    mov  x21, #2
    mov  x22, #1
    b    run_test
ic_7432:                     // OR
    ldr  x19, =gates2
    mov  x20, #4
    mov  x21, #2
    mov  x22, #3
    b    run_test
ic_7427:                     // NOR (3 entradas)
    ldr  x19, =gates3
    mov  x20, #3
    mov  x21, #3
    mov  x22, #2
 
run_test:
    bl   test_ic
    b    main_loop           // ---- 5) volver al inciso 1 ----
 
// ============================================================================
//  test_ic : prueba todas las compuertas del IP configurado en x19..x22,
//            decide el estado e imprime el mensaje correspondiente.
//  (es funcion que llama a otras -> guarda x30 y los registros que usa)
// ============================================================================
test_ic:
    stp  x29, x30, [sp, #-16]!       // guardar LR (hace bl's adentro)
    stp  x23, x24, [sp, #-16]!
    stp  x25, x26, [sp, #-16]!
    stp  x27, x28, [sp, #-16]!
 
    mov  x23, #0                     // mascara de compuertas dañadas
    mov  x24, #0                     // indice de compuerta
    mov  x25, #1
    lsl  x25, x25, x21               // x25 = 2^entradas = cantidad de combos
 
gate_loop:
    cmp  x24, x20
    b.ge test_done
    mov  x27, #0                     // combo actual
 
combo_loop:
    cmp  x27, x25
    b.ge gate_ok                     // paso todas las combinaciones -> OK
 
    add  x26, x19, x24, lsl #2       // direccion de la entrada de esta compuerta
    ldrb w9,  [x26]                  // shiftA
    ldrb w10, [x26, #1]              // shiftB
    ldrb w11, [x26, #2]              // shiftC (0xFF = no hay)
    // (shiftY se recarga despues de llamar al hardware)
 
    and  x13, x27, #1                // a = bit0 del combo
    lsr  x14, x27, #1
    and  x14, x14, #1                // b = bit1
    lsr  x15, x27, #2
    and  x15, x15, #1                // c = bit2
 
    // ---- construir la excitacion en x0 (poner las entradas) ----
    mov  x0, #0
    cbz  x13, skipA
    mov  x16, #1
    lsl  x16, x16, x9
    orr  x0, x0, x16
skipA:
    cbz  x14, skipB
    mov  x16, #1
    lsl  x16, x16, x10
    orr  x0, x0, x16
skipB:
    cmp  x21, #3                     // solo hay C si son 3 entradas
    b.ne skipC
    cbz  x15, skipC
    mov  x16, #1
    lsl  x16, x16, x11
    orr  x0, x0, x16
skipC:
 
    // ---- salida esperada (la calculo en software para comparar) ----
    cmp  x22, #1
    b.eq e_and
    cmp  x22, #0
    b.eq e_nand
    cmp  x22, #3
    b.eq e_or
    orr  x28, x13, x14               // NOR
    orr  x28, x28, x15
    eor  x28, x28, #1
    b    e_done
e_and:
    and  x28, x13, x14
    b    e_done
e_nand:
    and  x28, x13, x14
    eor  x28, x28, #1
    b    e_done
e_or:
    orr  x28, x13, x14
e_done:
    and  x28, x28, #1                // x28 = salida esperada
 
    // ---- excitar hardware, esperar 10 ms, leer la salida real ----
    bl   excitar_hw                  // x0 = valor devuelto por el IC
    str  x0, [sp, #-16]!             // salvar resultado (nanosleep pisa x0)
    bl   delay_10ms
    ldr  x0, [sp], #16               // recuperar resultado
 
    ldrb w9, [x26, #3]               // shiftY
    lsr  x10, x0, x9
    and  x10, x10, #1                // x10 = salida real
    cmp  x10, x28
    b.ne gate_failed                 // no coincide -> compuerta dañada
 
    add  x27, x27, #1                // siguiente combinacion
    b    combo_loop
 
gate_failed:
    mov  x11, #1                     // marcar bit x24 en la mascara
    lsl  x11, x11, x24
    orr  x23, x23, x11
gate_ok:
    add  x24, x24, #1                // siguiente compuerta
    b    gate_loop
 
test_done:
    // ---- 4) decidir e imprimir el resultado ----
    cbz  x23, print_ok               // ninguna dañada -> IC. OK
 
    mov  x9, #1                      // ¿estan TODAS dañadas?
    lsl  x9, x9, x20
    sub  x9, x9, #1                  // mascara = (1<<count)-1
    cmp  x23, x9
    b.eq print_mal                   // todas -> IC MAL
 
    // ---- parcial: imprimir cada compuerta dañada ----
    mov  x24, #0
part_loop:
    cmp  x24, x20
    b.ge test_ret
    lsr  x9, x23, x24
    and  x9, x9, #1
    cbz  x9, part_next
 
    ldr  x1, =msg_comp1              // "COMPUERTA "
    mov  x2, #len_comp1
    bl   puts
 
    add  x9, x24, #1                 // numero de compuerta (1..4)
    add  x9, x9, #48                 // a ASCII
    ldr  x10, =digito
    strb w9, [x10]
    ldr  x1, =digito                 // imprimir el digito
    mov  x2, #1
    bl   puts
 
    ldr  x1, =msg_comp2              // " DANADA\n"
    mov  x2, #len_comp2
    bl   puts
part_next:
    add  x24, x24, #1
    b    part_loop
    b    test_ret
 
print_ok:
    ldr  x1, =msg_ok
    mov  x2, #len_ok
    bl   puts
    b    test_ret
print_mal:
    ldr  x1, =msg_mal
    mov  x2, #len_mal
    bl   puts
 
test_ret:
    ldp  x27, x28, [sp], #16
    ldp  x25, x26, [sp], #16
    ldp  x23, x24, [sp], #16
    ldp  x29, x30, [sp], #16
    ret
 
// ============================================================================
//  excitar_hw : *** SIMULADOR del hardware (para poder correr en QEMU) ***
//  En el sistema real esta funcion la reemplaza el hardware fisico: tu le
//  inyectas la excitacion en X0 y el te devuelve X0 con las salidas puestas.
//  Aqui calculo las salidas de un IC SANO para poder probar el programa.
//  Entrada: x0 = excitacion (bits de entrada)   Salida: x0 = con bits de salida
// ============================================================================
excitar_hw:
    mov  x10, x0                     // copia de trabajo (conserva entradas)
    mov  x12, x20                    // cantidad de compuertas
    mov  x13, #0                     // indice
hw_loop:
    cmp  x13, x12
    b.ge hw_done
    add  x14, x19, x13, lsl #2
    ldrb w5, [x14]                   // shiftA
    ldrb w6, [x14, #1]               // shiftB
    ldrb w7, [x14, #2]               // shiftC
    ldrb w8, [x14, #3]               // shiftY
 
    lsr  x1, x0, x5
    and  x1, x1, #1                  // a
    lsr  x2, x0, x6
    and  x2, x2, #1                  // b
    mov  x3, #0
    cmp  w7, #0xFF
    b.eq hw_calc
    lsr  x3, x0, x7
    and  x3, x3, #1                  // c
hw_calc:
    cmp  x22, #1
    b.eq hw_and
    cmp  x22, #0
    b.eq hw_nand
    cmp  x22, #3
    b.eq hw_or
    orr  x4, x1, x2                  // NOR
    orr  x4, x4, x3
    eor  x4, x4, #1
    b    hw_y
hw_and:
    and  x4, x1, x2
    b    hw_y
hw_nand:
    and  x4, x1, x2
    eor  x4, x4, #1
    b    hw_y
hw_or:
    orr  x4, x1, x2
hw_y:
    and  x4, x4, #1
 
    // *** Para PROBAR la deteccion de fallas, descomenta estas 3 lineas:
    //     invierten la salida de la compuerta 2 -> veras "COMPUERTA 2 DANADA"
    // cmp  x13, #1
    // b.ne hw_set
    // eor  x4, x4, #1
hw_set:
    cbz  x4, hw_next                 // si y=0 el bit ya esta en 0
    mov  x15, #1
    lsl  x15, x15, x8
    orr  x10, x10, x15
hw_next:
    add  x13, x13, #1
    b    hw_loop
hw_done:
    mov  x0, x10
    ret
 
// ============================================================================
//  delay_10ms : espera 10 milisegundos (syscall nanosleep)
// ============================================================================
delay_10ms:
    ldr  x0, =timespec
    mov  x1, #0
    mov  x8, #101                    // syscall nanosleep
    svc  #0
    ret
 
// ============================================================================
//  puts : imprime en pantalla.  Entrada: x1 = direccion,  x2 = longitud
// ============================================================================
puts:
    mov  x0, #1                      // fd = stdout
    mov  x8, #64                     // syscall write
    svc  #0
    ret
 