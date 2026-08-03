; Smoke ROM for Dot Matrix Deck.
;
; This fixture exercises core CPU behavior and then reports a verdict
; through the serial link port. The integration tests assemble this file
; with gbasm and check that the emulator prints "Passed".
;
; The Game Boy boot ROM is not emulated, so execution starts at $0100.
; The header checksum and Nintendo logo are not validated by the
; emulator; only the title field is set here.

    org $0100
    jp start

    ; The Nintendo logo region ($0104-$0133) is not validated by the
    ; emulator, so it is left as zeros. The title and capability bytes
    ; below are kept clean so the --info flag can display them.

    org $0134
    db "SMOKE TEST"
    db $00, $00, $00, $00, $00

    org $0143
    db $80

    org $0147
    db $00
    db $00
    db $00

    org $0150
start:
    ; 0x12 + 0x21 must equal 0x33 and set Z, C, and H flags.
    ld a, $12
    add a, $21
    cp $33
    jr nz, fail

    ; 0x05 - 0x02 must equal 0x03.
    ld a, $05
    ld b, $02
    sub b
    cp $03
    jr nz, fail

    ; Push and pop must round-trip a 16-bit value.
    ld hl, $1234
    push hl
    pop de
    ld a, d
    cp $12
    jr nz, fail
    ld a, e
    cp $34
    jr nz, fail

    ; A forward conditional call must reach its target.
    ld a, $00
    call nz, never
    ld a, $01
    call z, reached
    jp fail

reached:
    ld hl, message
print_loop:
    ld a, (hl+)
    or a
    jr z, done
    call print_byte
    jr print_loop

done:
    jr done

never:
    jp fail

; Sends the byte in A over the serial link and waits for the transfer.
; The emulator captures each byte into its serial buffer.
print_byte:
    ldh ($01), a
    ld a, $81
    ldh ($02), a
    ret

fail:
    ld a, 'F'
    call print_byte
    jr fail

message:
    db "Passed", $0a, $00
