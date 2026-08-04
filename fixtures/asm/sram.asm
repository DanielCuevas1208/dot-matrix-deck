; sram.asm - verifies battery-backed external RAM for the headless runner.
;
; The ROM enables MBC1 external RAM and stores a marker across the first
; RAM bank. On a fresh start it writes the marker and reads it back. When
; a save file is loaded the marker is already present, so the ROM checks
; that the whole saved page survived. It prints PASS over the serial port.
; Regenerate sram.gb with `zig build fixtures`.

    ORG $0000

    ORG $0100
    NOP
    JP init

    ORG $0134
    DB "SRAM TEST"          ; cartridge title
    ORG $0143
    DB $80                  ; CGB flag
    ORG $0144
    DB $00                  ; licensee
    ORG $0147
    DB $03                  ; MBC1 + RAM + battery
    ORG $0148
    DB $00                  ; 32KB ROM
    ORG $0149
    DB $03                  ; 32KB RAM
    ORG $014C
    DB $00                  ; header checksum
    ORG $014E
    DB $00, $00             ; version
    ORG $0150

init:
    LD A,$0A
    LD ($0000),A            ; enable RAM
    LD A,($A000)
    CP $5A
    JR Z,check_loaded       ; the marker is already saved

    ; Fresh RAM: write the marker across the bank and read it back.
    LD A,$5A
    LD ($A000),A
    LD ($A001),A
    LD ($AFFF),A
    LD A,($A000)
    CP $5A
    JR NZ,fail
    LD A,($A001)
    CP $5A
    JR NZ,fail
    LD A,($AFFF)
    CP $5A
    JR NZ,fail
    LD HL,msg_pass
    CALL print_string
    JR done

check_loaded:
    ; A save file was loaded. Confirm the whole saved page came back.
    LD A,($A001)
    CP $5A
    JR NZ,fail
    LD A,($AFFF)
    CP $5A
    JR NZ,fail
    LD HL,msg_pass
    CALL print_string

done:
    JR done

fail:
    LD HL,msg_fail
    CALL print_string
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
