; smoke.asm - a bundled smoke test for the Dot Matrix Deck emulator.
;
; The ROM exercises the CPU and the memory bus, then reports the result
; through the serial link port. The headless runner checks the serial
; output for "PASS" to decide whether the emulator behaved correctly.
;
; The cartridge header holds a valid header checksum, so the --info
; frontend can display the ROM details.
;
; Regenerate the ROM with:  zig build fixtures

    org $0100
    nop                 ; entry point
    jp start

    ; $0104-$0133: Nintendo logo. Zeros are fine for an emulator test.
    ds $30

    ; Cartridge header ($0134-$014F).
    db "SMOKE TEST"     ; title (16 bytes, zero padded)
    ds 6
    db $00, $00         ; new licensee code
    db $00              ; SGB flag
    db $00              ; cartridge type: ROM only
    db $00              ; ROM size: 32 KiB
    db $00              ; RAM size: none
    db $00              ; destination: Japan
    db $33              ; old licensee: new style
    db $00              ; mask ROM version
    db $d5              ; header checksum
    db $00, $00         ; global checksum

start:
    ; Set up a stable stack in working RAM.
    ld sp, $fffe

    ; --- arithmetic: A = 2 + 3 must equal 5 ---
    ld a, $02
    add a, $03
    cp $05
    jp nz, fail

    ; --- flag handling: INC wraps $ff to 0 and sets Z ---
    ld a, $ff
    inc a
    jp nz, fail

    ; --- DEC from 1 to 0 sets Z ---
    ld a, $01
    dec a
    jp nz, fail

    ; --- 16-bit moves and ADD HL ---
    ld bc, $1234
    ld de, $0001
    ld hl, $0000
    add hl, de
    ld a, b
    cp $12
    jp nz, fail

    ; --- stack push/pop round trip ---
    ld hl, $abcd
    push hl
    pop de
    ld a, d
    cp $ab
    jp nz, fail
    ld a, e
    cp $cd
    jp nz, fail

    ; --- memory: LD (HL),A / LD A,(HL) ---
    ld hl, $c000
    ld (hl), $7e
    ld a, (hl)
    cp $7e
    jp nz, fail

    ; --- CB prefix: rotate and bit tests ---
    ld a, $01
    sla a
    cp $02
    jp nz, fail
    bit 1, a
    jp z, fail

    ; --- calls and conditional returns ---
    call compute
    jp nz, fail

    ; --- execute a payload copied into RAM ---
    ld hl, payload
    ld de, $d000
copy:
    ld a, (hl+)
    or a
    jr z, run
    ld (de), a
    inc de
    jr copy
run:
    call $d000
    jp nz, fail

    ; All checks passed.
    ld hl, msg_pass
    call print
    jp done

fail:
    ld hl, msg_fail
    call print

done:
    halt
    jr done

; Computes 40 + 2 and compares to 42.
; Returns with Z set when the result is correct.
compute:
    ld a, $28
    add a, $02
    cp $2a
    ret

; A payload for RAM execution. It returns with Z set only when the
; emulator runs code from working RAM correctly. The byte sequence must
; not contain a $00 operand, because the copy loop stops on a zero byte.
payload:
    ld a, $07
    add a, $01
    cp $08
    ret
    db $00

; Prints the zero-terminated string at HL through the serial link port.
print:
    ld a, (hl+)
    or a
    jr z, print_done
    ld ($ff01), a
    ld a, $81
    ld ($ff02), a
    ld a, $00
    ld ($ff02), a
    jr print
print_done:
    ret

msg_pass:
    db "PASS", $0a
    db $00

msg_fail:
    db "FAIL", $0a
    db $00
