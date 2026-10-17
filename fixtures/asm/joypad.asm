; joypad.asm - verifies the FF00 joypad register for the headless runner.
;
; The ROM checks active-low column selection and stored select bits.
; It then prints PASS or FAIL over the serial port. Regenerate joypad.gb with
; `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "JOYPAD TEST"        ; cartridge title
    ORG $0143
    DB $80                  ; CGB flag
    ORG $0144
    DB $00                  ; licensee
    ORG $0147
    DB $00                  ; ROM only
    ORG $0148
    DB $00                  ; 32KB ROM
    ORG $0149
    DB $00                  ; no external RAM
    ORG $014C
    DB $0F                  ; header checksum
    ORG $014E
    DB $00, $00             ; version
    ORG $0150

init:
    ; Default state: no column selected, all keys released.
    LDH A,($FF00)
    CP $FF
    JR NZ,fail

    ; Select the D-pad column. Bit 4 goes low.
    LD A,$E0
    LDH ($FF00),A
    LDH A,($FF00)
    CP $EF
    JR NZ,fail

    ; Stored select bits read back from the last write.
    LD A,$20
    LDH ($FF00),A
    LDH A,($FF00)
    AND $30
    CP $20
    JR NZ,fail

    ; Select the buttons column. Bit 5 goes low.
    LD A,$D0
    LDH ($FF00),A
    LDH A,($FF00)
    CP $DF
    JR NZ,fail

    LD A,$10
    LDH ($FF00),A
    LDH A,($FF00)
    AND $30
    CP $10
    JR NZ,fail

    ; Select both columns.
    LD A,$C0
    LDH ($FF00),A
    LDH A,($FF00)
    CP $CF
    JR NZ,fail

    ; Deselect both columns.
    LD A,$F0
    LDH ($FF00),A
    LDH A,($FF00)
    CP $FF
    JR NZ,fail

    ; Unrelated bits in the write are ignored.
    LD A,$8F
    LDH ($FF00),A
    LDH A,($FF00)
    CP $CF
    JR NZ,fail

    LD HL,msg_pass
    CALL print_string
    JR done

fail:
    LD HL,msg_fail
    CALL print_string
done:
    JR done

; Prints a zero-terminated string pointed to by HL over the serial port.
print_string:
    LD A,(HL+)
    OR A
    RET Z
    CALL print_char
    JR print_string

print_char:
    LDH ($01),A
    LD A,$81
    LDH ($02),A
    RET

msg_pass:
    DB "PASS", $0D, $0A, $00

msg_fail:
    DB "FAIL", $0D, $0A, $00

    PAD $8000
