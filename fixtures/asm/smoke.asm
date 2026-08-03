; smoke.asm - minimal SM83 self-test for the dot-matrix-deck emulator.
;
; The ROM runs a few arithmetic and stack checks. On success it prints
; "Passed" over the serial port and hangs. On failure it prints 'F' in a
; tight loop. The headless runner and CI use this ROM to verify the core.
; Regenerate the matching smoke.gb with `zig build fixtures`.

    ORG $0000                   ; image base so the ROM is a full $8000 bytes
    ORG $0100
    JP start                    ; entry point

    ORG $0134
    DB "SMOKE TEST"             ; title

    ORG $0143
    DB $80                      ; CGB flag: works on Game Boy Color

    ORG $0150
start:
    LD A,$12
    ADD A,$21
    CP $33
    JR NZ, fail_print
    LD A,$05
    LD B,$02
    SUB B
    CP $03
    JR NZ, fail_print
    LD HL,$1234
    PUSH HL
    POP DE
    LD A,D
    CP $12
    JR NZ, fail_print
    LD A,E
    CP $34
    JR NZ, fail_print
    LD A,$00
    CALL NZ, fail               ; must not be taken
    LD A,$01
    CALL Z, print_message       ; Z is set, so this prints the message
    JP fail_print               ; unreachable

print_message:
    LD HL, message
loop:
    LD A,(HL+)
    OR A
    JR Z, done
    CALL print_char
    JR loop

done:
    JR done                     ; success: hang here

fail:
    JP fail_print

print_char:
    LDH ($01),A                 ; SB = character
    LD A,$81
    LDH ($02),A                 ; SC = start transfer
    RET

fail_print:
    LD A,$46                    ; 'F'
    CALL print_char
    JR fail_print

message:
    DB "Passed", $0A, $00

    PAD $8000
