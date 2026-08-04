; mbc5.asm - verifies MBC5 cartridge banking for the headless runner.
;
; The ROM switches ROM banks through the low and high registers and checks
; banked RAM. It prints PASS or FAIL over the serial port. Regenerate
; mbc5.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "MBC5 BANK TEST"     ; cartridge title
    ORG $0143
    DB $80                  ; CGB flag
    ORG $0147
    DB $19                  ; MBC5
    ORG $0148
    DB $01                  ; 64KB ROM
    ORG $0149
    DB $03                  ; 32KB RAM
    ORG $014C
    DB $00                  ; header checksum
    ORG $014E
    DB $00, $00             ; version
    ORG $0150

init:
    ; Bank 1 is the default. Check its marker.
    LD A,($4000)
    CP $11
    JR NZ,fail

    ; Switch to bank 2 through the low register.
    LD A,$02
    LD ($2000),A
    LD A,($4000)
    CP $22
    JR NZ,fail

    ; Bank 0 is addressable, unlike MBC1.
    LD A,$00
    LD ($2000),A
    LD A,($4000)
    CP $00
    JR NZ,fail

    ; Switch back to bank 1.
    LD A,$01
    LD ($2000),A
    LD A,($4000)
    CP $11
    JR NZ,fail

    ; Enable external RAM and use RAM bank 0.
    LD A,$0A
    LD ($0000),A
    LD A,$42
    LD ($A000),A
    LD A,($A000)
    CP $42
    JR NZ,fail

    ; Switch to RAM bank 2 and store a different byte.
    LD A,$02
    LD ($4000),A
    LD A,$24
    LD ($A000),A
    LD A,($A000)
    CP $24
    JR NZ,fail

    ; Back on RAM bank 0 the first byte survives.
    LD A,$00
    LD ($4000),A
    LD A,($A000)
    CP $42
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

    ORG $4000
    DB $11

    ORG $8000
    DB $22

    PAD $FFFF
