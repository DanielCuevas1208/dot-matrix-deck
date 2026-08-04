; banking.asm - verifies MBC1 cartridge banking for the headless runner.
;
; The ROM switches ROM banks and checks a marker byte in each one. It
; prints PASS or FAIL over the serial port. Regenerate banking.gb with
; `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "MBC1 BANK TEST"     ; cartridge title
    ORG $0143
    DB $80                  ; CGB flag
    ORG $0144
    DB $00                  ; licensee
    ORG $0147
    DB $01                  ; MBC1
    ORG $0148
    DB $01                  ; 64KB ROM
    ORG $0149
    DB $00                  ; no external RAM
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

    ; Switch to bank 2 and check its marker.
    LD A,$02
    LD ($2000),A
    LD A,($4000)
    CP $22
    JR NZ,fail

    ; Switch to bank 3 and check its marker.
    LD A,$03
    LD ($2000),A
    LD A,($4000)
    CP $33
    JR NZ,fail

    ; Switch back to bank 1 and check again.
    LD A,$01
    LD ($2000),A
    LD A,($4000)
    CP $11
    JR NZ,fail

    ; The 0000-3FFF window stays pinned to bank 0.
    LD A,($0000)
    CP $00
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

    ORG $C000
    DB $33

    PAD $FFFF
