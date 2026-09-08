; ============================================================================
; ESXDOS DOT COMMAND: .ZXDB
; Busca y descarga juegos en formatos TAP, TZX, Z80, etc.
; desde http://zxdb.remysharp.com
; Hardware: ZX Spectrum + DivTiesus (ESP8266 UART $FC3B/$FD3B)
; Compilar desde src: sjasmplus ZXDB.asm --nologo
;
; Uso: .ZXDB -h | .ZXDB -i | .ZXDB -s "manic miner"
; API: ^id^titulo^fichero^tamano^opciones^anio^
;
; ZX-Uno UART register definitions compatible with netman-zx
; by Alex Nihirash:
; https://github.com/nihirash/netman-zx
; ============================================================================

        OUTPUT "../bin/ZXDB"
        ORG $2000

ZXUNO_ADDR      EQU $FC3B
ZXUNO_DATA      EQU $FD3B
UART_DATA_REG   EQU $C6
UART_STAT_REG   EQU $C7
F_OPEN          EQU $9A
F_CLOSE         EQU $9B
F_WRITE         EQU $9E
SCR_CT          EQU $5C8C       ; Contador antes de mostrar "scroll?".
DF_CC           EQU $5C84       ; Direccion de pantalla del siguiente caracter.

HTTP_BUF        EQU $C000       ; Peticion HTTP
DOWNLOAD_BUF    EQU $B000       ; Bloque de escritura SD de 512 bytes
TOKEN_BUF       EQU $C100
RESULT_IDS      EQU $C200       ; 10 x 8 bytes
RESULT_NAMES    EQU $C300       ; 10 x 128 bytes
RESULT_SIZES    EQU $C800       ; 10 x 8 bytes (tamano decimal)
MAX_RESULTS     EQU 10
ID_SLOT_SIZE    EQU 8
NAME_SLOT_SIZE  EQU 128          ; Conserva nombres largos y su extension.
WRITE_CHUNK_HI  EQU 2           ; $0200 = 512 bytes

; ============================================================================
; ENTRADA
; ============================================================================
start:
        push af
        push bc
        push de
        push hl
        xor a
        ld (result_count), a
        ld (ipd_remaining), a
        ld (ipd_remaining+1), a

        call skip_spaces
        ld a, (hl)
        cp '-'
        jp nz, show_usage
        inc hl
        ld a, (hl)
        inc hl
        cp 'A'                 ; Aceptar parametros en mayusculas/minusculas.
        jr c, .option_ready
        cp 'Z'+1
        jr nc, .option_ready
        add a, 'a'-'A'
.option_ready:
        ld c, a                 ; Guardar la opcion normalizada.
        cp 's'
        jr z, .validate_search
        cp 'h'
        jr z, .validate_no_args
        cp 'i'
        jr z, .validate_no_args
        cp 't'
        jp nz, show_usage
.validate_no_args:
        call skip_spaces        ; -h, -i y -t no admiten mas argumentos.
        ld a, (hl)
        or a
        jr z, .option_valid
        cp 13
        jr z, .option_valid
        cp ':'                  ; Fin alternativo desde BASIC.
        jp nz, show_usage
        jr .option_valid
.validate_search:
        ld a, (hl)              ; -s debe terminar antes del texto buscado.
        cp ' '
        jp nz, show_usage
.option_valid:
        ld a, c
        cp 'h'
        jp z, show_help          ; La ayuda no necesita inicializar la UART.
        push af
        push hl
        call init_divtiesus_hw
        jr nc, .hw_ok
        pop hl
        pop af
        ld hl, txt_err_hw
        call print_string
        jp exit_error
.hw_ok:
        pop hl
        pop af
        cp 'i'
        jp z, mode_info
        cp 't'
        jp z, mode_trace
        cp 's'
        jp z, mode_search
        jp show_usage

; ============================================================================
; MODOS
; ============================================================================
mode_info:
        call check_network_with_reconnect
        jr c, .not_connected
        ld hl, txt_network_connected
        call print_string
        ld hl, cmd_cwjap
        call esp_send_cmd_string
        call print_ssid_info
        jp c, err_info
        call flush_uart_rx_fast
        ld hl, cmd_cifsr
        call esp_send_cmd_string
        call print_cifsr_info
        jp c, err_info
        jp exit_success
.not_connected:
        ld hl, txt_network_not_connected
        call print_string
        jp exit_success

mode_trace:
        ld hl, txt_trace
        call print_string
        ld hl, cmd_gmr
        ld b, 20
        call trace_cmd
        ld hl, cmd_cifsr
        ld b, 10
        call trace_cmd
        ld hl, cmd_cipmux
        ld b, 5
        call trace_cmd
        ld hl, cmd_domain
        ld b, 20
        call trace_cmd
        ld hl, cmd_connect_http
        ld b, 60
        call trace_cmd
        ld hl, cmd_cipclose
        ld b, 10
        call trace_cmd
        jp exit_success

mode_search:
        call skip_spaces
        ld a, (hl)
        or a
        jp z, show_usage
        cp 13                  ; Fin de linea de comandos de esxDOS.
        jp z, show_usage
        cp ':'                 ; Separador/fin alternativo desde BASIC.
        jp z, show_usage
        cp '"'
        jr nz, .arg_ready
        inc hl
        ld a, (hl)             ; No admitir tampoco una cadena vacia: "".
        or a
        jp z, show_usage
        cp 13
        jp z, show_usage
        cp '"'
        jp z, show_usage
.arg_ready:
        push hl
        call check_network_with_reconnect
        jr nc, .network_ok
        pop hl
        jp err_no_wifi
.network_ok:
        call connect_remy_http
        jr nc, .connected
        pop hl
        jp err_connect
.connected:
        pop hl
        call build_search_request
        call esp_send_data
        jp c, err_send
        call http_expect_2xx_and_body
        jp c, err_http
        ld a, $FF               ; Permitir scroll automatico sin preguntar.
        ld (SCR_CT), a
        ld hl, txt_search_header
        call print_string
        call parse_search_rows
        ld a, (result_count)
        or a
        jp z, err_no_results

        call ask_result_number
        jr nc, .result_selected
        ld hl, txt_cancelled
        call print_string
        call close_connection_fast
        jp exit_success
.result_selected:
        call connect_remy_http
        jp c, err_connect
        call build_download_request
        call esp_send_data
        jp c, err_send
        call http_expect_2xx_and_body
        jp c, err_http
        call download_selected_file
        jp c, err_sd
        ld hl, txt_download_ok
        call print_string
        jp exit_success

; ============================================================================
; CONEXION HTTP
; ============================================================================
connect_remy_http:
        call close_connection
        ld hl, cmd_cipmux
        call esp_send_cmd_string
        call wait_ok
        ret c
        ld hl, cmd_connect_http
        call esp_send_cmd_string
        call wait_ok_long
        ret

close_connection:
        ld hl, cmd_cipclose
        call esp_send_cmd_string
        call flush_uart_rx       ; CLOSED o ERROR son validos aqui.
        xor a
        ld (ipd_remaining), a
        ld (ipd_remaining+1), a
        ret

; Cancelacion inmediata: el siguiente arranque terminara de vaciar la UART.
close_connection_fast:
        ld hl, cmd_cipclose
        call esp_send_cmd_string
        call flush_uart_rx_fast
        xor a
        ld (ipd_remaining), a
        ld (ipd_remaining+1), a
        ret

; Comprueba la conexion y, si se ha perdido, reactiva la autoconexion del
; ESP8266 y lo reinicia para que reutilice las credenciales guardadas por
; .wconf. La recuperacion solo se ejecuta despues de fallar la comprobacion
; inicial, por lo que no retrasa el funcionamiento normal.
check_network_with_reconnect:
        call check_network_ready
        ret nc
        ld hl, txt_reconnecting_wifi
        call print_string
        call flush_uart_rx_fast
        ld hl, cmd_cwautoconn
        call esp_send_cmd_string
        jr c, .reset_module
        call wait_ok
        ; Algunos firmwares pueden no reconocer CWAUTOCONN. Aun asi se intenta
        ; el reinicio: una configuracion persistente anterior puede reconectar.
.reset_module:
        call flush_uart_rx_fast
        ld hl, cmd_rst
        call esp_send_cmd_string
        jr c, .failed
        call wait_ok
        jr c, .retry_network
        call wait_ready_long
.retry_network:
        ld b, 8
.retry:
        push bc
        call wifi_reconnect_delay
        call check_network_ready
        pop bc
        ret nc
        djnz .retry
.failed:
        scf
        ret

; AT+RST responde primero OK y despues "ready". Esperarlo evita enviar CIFSR
; mientras el firmware todavia se esta reiniciando.
wait_ready_long:
        ld b, 60
.seek_r:
        call esp_read_raw
        jr c, .timeout
        cp 'r'
        jr nz, .seek_r
        call esp_read_raw
        jr c, .timeout
        cp 'e'
        jr nz, .seek_r
        call esp_read_raw
        jr c, .timeout
        cp 'a'
        jr nz, .seek_r
        call esp_read_raw
        jr c, .timeout
        cp 'd'
        jr nz, .seek_r
        call esp_read_raw
        jr c, .timeout
        cp 'y'
        jr nz, .seek_r
        or a
        ret
.timeout:
        djnz .seek_r
        scf
        ret

; Pausa aproximada de medio segundo a 3,5 MHz. Se usa solamente durante la
; recuperacion para dar tiempo al ESP8266 a asociarse y obtener una direccion.
wifi_reconnect_delay:
        push af
        push de
        ld de, 0
.loop:
        dec de
        ld a, d
        or e
        jr nz, .loop
        pop de
        pop af
        ret

check_network_ready:
        ld b, 3
.retry:
        push bc
        call flush_uart_rx_fast
        ld hl, cmd_cifsr
        call esp_send_cmd_string
.find_quote:
        call esp_read_raw
        jr c, .failed
        cp '"'
        jr nz, .find_quote
        call esp_read_raw
        jr c, .failed
        cp '0'
        jr z, .failed
        pop bc
        call flush_uart_rx_fast
        or a
        ret
.failed:
        pop bc
        djnz .retry
        scf
        ret

; ============================================================================
; PETICIONES HTTP
; ============================================================================
build_search_request:
        push hl
        ld de, HTTP_BUF
        ld hl, req_search_head
        call copy_string
        pop hl
.copy_term:
        ld a, (hl)
        or a
        jr z, .done
        cp '"'
        jr z, .done
        cp 13
        jr z, .done
        cp ' '
        jr nz, .store
        ld a, '*'                ; La API usa * para los espacios.
.store:
        ld (de), a
        inc de
        inc hl
        jr .copy_term
.done:
        ld hl, req_search_tail
        call copy_string
        call save_request_length
        ret

build_download_request:
        ld de, HTTP_BUF
        ld hl, req_download_head
        call copy_string
        push de                 ; Conservar puntero de escritura HTTP.
        ld a, (selected_index)
        call get_id_slot
        pop de
        call copy_string
        ld hl, req_download_tail
        call copy_string
        call save_request_length
        ret

save_request_length:
        ld hl, HTTP_BUF
        ex de, hl
        or a
        sbc hl, de
        ld (request_length), hl
        ret

esp_send_data:
        ld hl, cmd_cipsend
        call esp_send_cmd_string
        ld bc, (request_length)
        call send_number_bc
        ld a, 13
        call esp_send_byte
        ret c
        ld a, 10
        call esp_send_byte
        ret c
        ld b, 0                 ; 256 lecturas para encontrar '>'.
.wait_prompt:
        call esp_read_raw
        jr c, .timeout
        cp '>'
        jr z, .send
        djnz .wait_prompt
.timeout:
        scf
        ret
.send:
        ld hl, HTTP_BUF
        ld bc, (request_length) ; B fue usado esperando el prompt.
.loop:
        ld a, b
        or c
        jr z, .sent
        ld a, (hl)
        call esp_send_byte
        ret c
        inc hl
        dec bc
        jr .loop
.sent:
        or a
        ret

; ============================================================================
; LECTOR TCP: QUITA +IPD,<longitud>: DE LA UART
; ============================================================================
net_read_byte:
        push bc
        push de
        push hl
        ld hl, (ipd_remaining)
        ld a, h
        or l
        jr z, .find_ipd
        call esp_read_raw
        jr c, .return
        dec hl
        ld (ipd_remaining), hl
        jr .return
.find_ipd:
.seek_plus:
        call esp_read_raw
        jr c, .return
        cp '+'
        jr nz, .seek_plus
        call esp_read_raw
        jr c, .return
        cp 'I'
        jr nz, .seek_plus
        call esp_read_raw
        jr c, .return
        cp 'P'
        jr nz, .seek_plus
        call esp_read_raw
        jr c, .return
        cp 'D'
        jr nz, .seek_plus
        call esp_read_raw
        jr c, .return
        cp ','
        jr nz, .seek_plus
        ld hl, 0
.read_len:
        call esp_read_raw
        jr c, .return
        cp ':'
        jr z, .len_done
        cp '0'
        jr c, .seek_plus
        cp '9'+1
        jr nc, .seek_plus
        sub '0'
        ld c, a
        ld b, 0
        ld d, h
        ld e, l
        add hl, hl              ; 2n
        add hl, hl              ; 4n
        add hl, de              ; 5n
        add hl, hl              ; 10n
        add hl, bc
        jr .read_len
.len_done:
        ld a, h
        or l
        jr z, .find_ipd
        dec hl
        ld (ipd_remaining), hl
        call esp_read_raw
.return:
        pop hl
        pop de
        pop bc
        ret

; Ruta rapida usada solo al copiar el cuerpo de la descarga. Mientras quedan
; bytes del +IPD evita guardar/restaurar registros en cada byte. Al agotarse
; el bloque vuelve al lector completo para localizar el siguiente +IPD.
net_read_download_byte:
        ld hl, (ipd_remaining)
        ld a, h
        or l
        jp z, net_read_byte
        call esp_read_raw_fast
        ret c
        dec hl
        ld (ipd_remaining), hl
        ret

; Valida cualquier HTTP 2xx y consume las cabeceras hasta CR LF CR LF.
http_expect_2xx_and_body:
.seek_h:
        call http_read_byte
        ret c
        cp 'H'
        jr nz, .seek_h
        call http_read_byte
        ret c
        cp 'T'
        jr nz, .seek_h
        call http_read_byte
        ret c
        cp 'T'
        jr nz, .seek_h
        call http_read_byte
        ret c
        cp 'P'
        jr nz, .seek_h
        call http_read_byte
        ret c
        cp '/'
        jr nz, .seek_h
.seek_space:
        call http_read_byte
        ret c
        cp ' '
        jr nz, .seek_space
        call http_read_byte
        ret c
        cp '2'
        jr nz, .bad
        call http_read_byte
        ret c
        call http_read_byte
        ret c
        xor a
        ld (header_state), a
.headers:
        call http_read_byte
        ret c
        ld b, a
        ld a, (header_state)
        or a
        jr z, .state0
        cp 1
        jr z, .state1
        cp 2
        jr z, .state2
        ld a, b                 ; Estado 3: CR LF CR, falta LF.
        cp 10
        jr z, .body
        xor a
        ld (header_state), a
        jr .headers
.state0:
        ld a, b
        cp 13
        jr nz, .headers
        ld a, 1
        ld (header_state), a
        jr .headers
.state1:
        ld a, b
        cp 10
        jr z, .set2
        xor a
        ld (header_state), a
        jr .headers
.set2:
        ld a, 2
        ld (header_state), a
        jr .headers
.state2:
        ld a, b
        cp 13
        jr z, .set3
        xor a
        ld (header_state), a
        jr .headers
.set3:
        ld a, 3
        ld (header_state), a
        jr .headers
.body:
        or a
        ret
.bad:
        scf
        ret

; La busqueda del servidor puede tardar mas que un timeout UART. Reintenta
; solo mientras se valida HTTP; la lectura del cuerpo conserva su timeout.
http_read_byte:
        push bc
        ld b, 20
.retry:
        call net_read_byte
        jr nc, .received
        djnz .retry
        pop bc
        scf
        ret
.received:
        pop bc
        or a
        ret

; ============================================================================
; PARSER ^id^titulo^fichero^tamano^opciones^anio^
; ============================================================================
parse_search_rows:
        xor a
        ld (result_count), a
.next:
        call net_read_byte
        ret c
        cp '^'
        jr nz, .next
        ld a, (result_count)
        cp MAX_RESULTS
        ret nc

        call get_id_slot
        ex de, hl               ; read_field_store recibe destino en DE.
        ld b, ID_SLOT_SIZE-1
        call read_field_store
        ret c

        ld de, TOKEN_BUF        ; Guardar temporalmente el titulo del juego.
        ld b, NAME_SLOT_SIZE-1
        call read_field_store
        ret c

        ld a, (result_count)    ; Nombre real del fichero
        call get_name_slot
        push hl                 ; Conservar inicio para mostrarlo despues.
        ex de, hl               ; Guardar el nombre en su entrada correcta.
        ld b, NAME_SLOT_SIZE-1
        call read_field_store
        pop hl
        ret c

        push hl
        call detect_machine_hint
        ld (display_machine), a
        pop hl

        ld a, (result_count)    ; Tamano decimal informado por la API
        call get_size_slot
        ex de, hl
        ld b, ID_SLOT_SIZE-1
        call read_field_store
        ret c
        call skip_field         ; Numero de opciones
        ret c
        ld de, year_buffer
        ld b, 7
        call read_field_store   ; Anio
        ret c
        call print_search_result
        ld a, (result_count)
        inc a
        ld (result_count), a
        jp .next

; DE=destino, B=maximo; consume siempre hasta '^'.
read_field_store:
        xor a
        ld (de), a
.loop:
        call net_read_byte
        ret c
        cp '^'
        jr z, .done
        ld c, a
        ld a, b
        or a
        jr z, .loop
        ld a, c
        ld (de), a
        inc de
        djnz .loop
        jr .loop
.done:
        xor a
        ld (de), a
        ret

read_field_store_print:
        xor a
        ld (de), a
.loop:
        call net_read_byte
        ret c
        cp '^'
        jr z, .done
        ld c, a
        ld a, (display_remaining)
        or a
        jr z, .dont_print
        dec a
        ld (display_remaining), a
        ld a, c
        call print_char_safe
.dont_print:
        ld a, b
        or a
        jr z, .loop
        ld a, c
        ld (de), a
        inc de
        djnz .loop
        jr .loop
.done:
        xor a
        ld (de), a
        ret

; Dibuja un resultado compacto. Los detalles permanecen juntos y solo pasan
; a la linea siguiente cuando no caben despues del titulo.
print_search_result:
        ld a, '('
        rst $10
        ld a, (result_count)
        inc a
        cp 10
        jr nz, .number
        xor a
.number:
        add a, '0'
        rst $10
        ld a, ')'
        rst $10
        ld a, ' '
        rst $10
        ld a, 4
        ld (display_column), a
        ld hl, TOKEN_BUF
.title_loop:
        ld a, (hl)
        or a
        jr z, .title_done
        ld a, (display_column)
        or a
        jr nz, .print_title_char
        ; Tras el salto automatico, omitir espacios e indentar bajo el titulo.
.skip_wrap_spaces:
        ld a, (hl)
        cp ' '
        jr nz, .indent_continuation
        inc hl
        ld a, (hl)
        or a
        jr z, .title_done
        jr .skip_wrap_spaces
.indent_continuation:
        ld b, 4
.indent_loop:
        ld a, ' '
        rst $10
        djnz .indent_loop
        ld a, 4
        ld (display_column), a
.print_title_char:
        ld a, (hl)
        call print_char_safe
        inc hl
        call advance_display_column
        jr .title_loop
.title_done:
        call get_details_length
        ld b, a
        ld a, (display_column)
        or a
        jr z, .indent
        add a, b
        cp 33
        jr c, .details
.new_line:
        ld a, 13
        rst $10
.indent:
        ld hl, txt_details_indent
        call print_string
.details:
        call print_machine_hint
        ld hl, txt_type_open
        call print_string
        call print_open_bracket
        ld a, (result_count)
        call get_name_slot
        call print_filename_type
        call print_close_bracket
        ld hl, txt_year_open
        call print_string
        ld hl, year_buffer
        call print_string
        ld a, ')'
        rst $10
        ld a, 13
        rst $10
        ret

; Longitud de: modelo opcional + tipo + espacio, parentesis y anio.
get_details_length:
        ld b, 0
        ld hl, year_buffer
.year:
        ld a, (hl)
        or a
        jr z, .base
        inc b
        inc hl
        jr .year
.base:
        ld a, b
        add a, 9               ; " [TZX] (" + ")"
        ld b, a
        ld a, (display_machine)
        or a
        ld a, b
        ret z
        ld a, (display_machine)
        cp 2
        ld a, b
        jr nz, .add_48
        add a, 6               ; " [128]"
        ret
.add_48:
        add a, 5               ; " [48]"
        ret

advance_display_column:
        ld a, (display_column)
        inc a
        cp 32
        jr c, .save
        xor a                   ; La ROM ya avanzo a la linea siguiente.
.save:
        ld (display_column), a
        ret

; Rutina conservada para mostrar cadenas completas cuando sea necesario.
print_game_title_full:
.loop:
        ld a, (hl)
        or a
        jr z, .done
        call print_char_safe
        inc hl
        jr .loop
.done:
        ld a, 13
        rst $10
        ret

; Muestra en mayusculas los tres caracteres de la ultima extension.
; Admite extensiones como TAP, TZX, Z80 y otros formatos de la API.
print_filename_type:
        ld de, 0               ; DE apuntara al texto tras el ultimo punto.
.find:
        ld a, (hl)
        or a
        jr z, .found_end
        inc hl
        cp '.'
        jr nz, .find
        ld d, h
        ld e, l
        jr .find
.found_end:
        ld a, d
        or e
        jr z, .unknown
        ex de, hl
        ld b, 3
.print:
        ld a, (hl)
        or a
        jr z, .unknown
        cp 'a'
        jr c, .emit
        cp 'z'+1
        jr nc, .emit
        sub 32
.emit:
        call print_char_safe
        inc hl
        djnz .print
        ret
.unknown:
        ld hl, txt_type_unknown
        jp print_string

; A=2 si contiene 128, A=1 si contiene 48 y A=0 si no indica modelo.
detect_machine_hint:
        push hl
        call filename_contains_128
        pop hl
        jr c, .is_128
        call filename_contains_48
        jr c, .is_48
        xor a
        ret
.is_48:
        ld a, 1
        ret
.is_128:
        ld a, 2
        ret

; Muestra la plataforma antes del tipo. Ambos campos ocupan seis columnas.
print_machine_hint:
        ld a, (display_machine)
        or a
        ret z
        cp 2
        ld hl, txt_machine_48
        jr nz, .selected
        ld hl, txt_machine_128
.selected:
        push hl
        ld a, ' '
        rst $10
        call print_open_bracket
        pop hl
        call print_string
        jp print_close_bracket

; Dibuja los corchetes directamente en pantalla. RST $10 imprime un espacio
; para avanzar el cursor y aplicar el atributo actual; despues se sustituye su
; bitmap. No depende de la fuente, de los UDG ni del idioma de la ROM.
print_open_bracket:
        ld de, bracket_open_bitmap
        jr print_custom_bracket

print_close_bracket:
        ld de, bracket_close_bitmap

print_custom_bracket:
        push af
        push bc
        push de
        push hl
        ld hl, (DF_CC)          ; Celda que va a ocupar el espacio.
        push hl
        ld a, ' '
        rst $10
        pop hl
        ld b, 8
.draw:
        ld a, (de)
        ld (hl), a
        inc de
        inc h                    ; Siguiente linea de pixeles de la celda.
        djnz .draw
        pop hl
        pop de
        pop bc
        pop af
        ret

filename_contains_128:
.loop:
        ld a, (hl)
        or a
        jr z, .no
        cp '1'
        jr nz, .next
        inc hl
        ld a, (hl)
        cp '2'
        jr nz, .back
        inc hl
        ld a, (hl)
        cp '8'
        jr z, .yes
        dec hl
.back:
        dec hl
.next:
        inc hl
        jr .loop
.yes:
        scf
        ret
.no:
        or a
        ret

filename_contains_48:
.loop:
        ld a, (hl)
        or a
        jr z, .no
        cp '4'
        jr nz, .next
        inc hl
        ld a, (hl)
        cp '8'
        jr z, .yes
        dec hl
.next:
        inc hl
        jr .loop
.yes:
        scf
        ret
.no:
        or a
        ret

read_field_print:
.loop:
        call net_read_byte
        ret c
        cp '^'
        ret z
        call print_char_safe
        jr .loop

skip_field:
.loop:
        call net_read_byte
        ret c
        cp '^'
        ret z
        jr .loop

; ============================================================================
; SELECCION Y DESCARGA DIRECTA (TAP, TZX, Z80, ETC.)
; ============================================================================
ask_result_number:
        ld hl, txt_select
        call print_string
.wait:
        call wait_numeric_key   ; Devuelve directamente indice 0..9.
        ret c                   ; BREAK: cancelar busqueda.
.validate:
        ld b, a
        ld a, (result_count)
        cp b
        jr z, .wait
        jr c, .wait
        ld a, b
        ld (selected_index), a
        cp 9
        jr z, .echo_zero
        add a, '1'
        jr .echo
.echo_zero:
        ld a, '0'
.echo:
        rst $10
        ld a, 13
        rst $10
        ret

; Lee directamente la matriz del teclado.
; $F7FE: bits 0..4 = 1,2,3,4,5
; $EFFE: bits 0..4 = 0,9,8,7,6
; Devuelve A=0..9 (indice de resultado; A=9 corresponde a la tecla 0).
wait_numeric_key:
        call wait_numbers_released
.scan:
        call check_break_key
        jr c, .cancel

        ld bc, $F7FE
        in a, (c)
        bit 0, a
        jr z, .key1
        bit 1, a
        jr z, .key2
        bit 2, a
        jr z, .key3
        bit 3, a
        jr z, .key4
        bit 4, a
        jr z, .key5

        ld bc, $EFFE
        in a, (c)
        bit 0, a
        jr z, .key0
        bit 1, a
        jr z, .key9
        bit 2, a
        jr z, .key8
        bit 3, a
        jr z, .key7
        bit 4, a
        jr z, .key6
        jr .scan

.key1: xor a
        jr .accepted
.key2: ld a, 1
        jr .accepted
.key3: ld a, 2
        jr .accepted
.key4: ld a, 3
        jr .accepted
.key5: ld a, 4
        jr .accepted
.key6: ld a, 5
        jr .accepted
.key7: ld a, 6
        jr .accepted
.key8: ld a, 7
        jr .accepted
.key9: ld a, 8
        jr .accepted
.key0: ld a, 9
.accepted:
        push af
        call wait_numbers_released
        pop af
        or a
        ret
.cancel:
        call wait_break_released
        scf
        ret

; BREAK en el Spectrum: CAPS SHIFT + SPACE.
check_break_key:
        ld bc, $FEFE            ; CAPS SHIFT = bit 0.
        in a, (c)
        bit 0, a
        jr z, .wait_space
        ld bc, $7FFE            ; SPACE = bit 0.
        in a, (c)
        bit 0, a
        jr z, .wait_caps
.not_pressed:
        or a
        ret

; Da un pequeno margen para que la segunda tecla de BREAK quede pulsada.
.wait_space:
        ld de, 20000            ; Margen para pulsaciones no simultaneas.
.space_loop:
        ld bc, $7FFE
        in a, (c)
        bit 0, a
        jr z, .pressed
        dec de
        ld a, d
        or e
        jr nz, .space_loop
        jr .not_pressed
.wait_caps:
        ld de, 20000
.caps_loop:
        ld bc, $FEFE
        in a, (c)
        bit 0, a
        jr z, .pressed
        dec de
        ld a, d
        or e
        jr nz, .caps_loop
        jr .not_pressed
.pressed:
        scf
        ret

wait_break_released:
.loop:
        ld bc, $FEFE
        in a, (c)
        bit 0, a
        jr z, .loop             ; Esperar a soltar CAPS SHIFT.
        ld bc, $7FFE
        in a, (c)
        bit 0, a
        jr z, .loop             ; Esperar tambien a soltar SPACE.
        ret

wait_numbers_released:
.loop:
        ld bc, $F7FE
        in a, (c)
        and $1F
        cp $1F
        jr nz, .loop
        ld bc, $EFFE
        in a, (c)
        and $1F
        cp $1F
        jr nz, .loop
        ret

download_selected_file:
        ld a, (selected_index)
        call get_size_slot
        call prepare_progress

        ld a, (selected_index)
        call get_name_slot
        call make_safe_83_name  ; HL original -> TOKEN_BUF en formato 8.3.
        call choose_free_83_name
        jr nc, .name_ready
        ld a, 1
        ld (sd_error_stage), a
        scf
        ret
.name_ready:
        ld hl, TOKEN_BUF
        ld (selected_name_ptr), hl
        ld hl, txt_saving
        call print_string
        ld hl, (selected_name_ptr)
        call print_string
        ld a, 13
        rst $10

        ld a, '*'
        ld b, $0E
        ld hl, (selected_name_ptr)
        rst $08
        db F_OPEN
        jr nc, .open_ok
        ld a, 1
        ld (sd_error_stage), a
        scf
        ret
.open_ok:
        ld (file_handle), a
        xor a
        ld (write_count), a
        ld (write_count+1), a
        ld (download_byte_in_page), a
        ld (download_pages), a
        ld (download_pages+1), a
        ld hl, DOWNLOAD_BUF
        ld (download_write_ptr), hl
        ld hl, txt_progress
        call print_string
.read:
        call net_read_download_byte
        jr c, .end
        ld hl, (download_write_ptr)
        ld (hl), a
        inc hl
        ld (download_write_ptr), hl
        ld hl, (write_count)
        inc hl
        ld (write_count), hl
        ld a, (download_byte_in_page)
        inc a
        ld (download_byte_in_page), a
        call z, progress_page_tick
        ld hl, (write_count)
        ld a, h
        cp WRITE_CHUNK_HI
        jr nz, .read
        ld a, l
        or a
        jr nz, .read
        call flush_write_buffer
        jr c, .write_error
        jr .read
.end:
        call flush_write_buffer
        jr c, .write_error
        call progress_finish
        ld a, (file_handle)
        rst $08
        db F_CLOSE
        or a
        ret
.write_error:
        ld a, 2
        ld (sd_error_stage), a
        ld a, (file_handle)
        rst $08
        db F_CLOSE
        scf
        ret

; Convierte el nombre recibido a un nombre seguro 8.3.
; Ejemplo: Target-Renegade128.tap -> TARGET-R.TAP
; Entrada: HL=nombre original. Salida: TOKEN_BUF terminado en cero.
make_safe_83_name:
        push hl
        ld de, 0               ; Buscar el ultimo punto, no el primero.
.find_last_dot:
        ld a, (hl)
        or a
        jr z, .last_dot_ready
        cp '.'
        jr nz, .find_next
        ld d, h
        ld e, l
.find_next:
        inc hl
        jr .find_last_dot
.last_dot_ready:
        ld (extension_dot_ptr), de
        pop hl
        ld de, TOKEN_BUF
        ld a, 8
        ld (name_base_remaining), a
.base:
        ld a, (hl)
        or a
        jp z, .finish
        push hl
        ld bc, (extension_dot_ptr)
        or a
        sbc hl, bc
        pop hl
        jp z, .extension
        ld a, (hl)
        inc hl
        call sanitize_83_char
        ld (de), a
        inc de
        ld a, (name_base_remaining)
        dec a
        ld (name_base_remaining), a
        jr nz, .base
        ld hl, (extension_dot_ptr)
        jp .extension
.extension:
        ld a, h
        or l
        jr z, .finish
        ld a, '.'
        ld (de), a
        inc de
        inc hl
        ld b, 3
.ext_loop:
        ld a, (hl)
        or a
        jr z, .finish
        inc hl
        call sanitize_83_char
        ld (de), a
        inc de
        djnz .ext_loop
.finish:
        xor a
        ld (de), a
        ret

; Conserva el nombre original si esta libre. Si ya existe, sustituye el
; ultimo caracter de la base por 2, 3, ... 9 sin sobrescribir ningun fichero.
choose_free_83_name:
        ld a, '*'
        ld b, $01              ; Abrir solo para lectura: comprobar existencia.
        ld hl, TOKEN_BUF
        rst $08
        db F_OPEN
        jr c, .available
        rst $08
        db F_CLOSE

        ld hl, TOKEN_BUF
.find_extension:
        ld a, (hl)
        or a
        jr z, .no_suffix_position
        cp '.'
        jr z, .suffix_position
        inc hl
        jr .find_extension
.suffix_position:
        dec hl
        ld (collision_char_ptr), hl
        ld a, '2'
        ld (collision_number), a
.try_number:
        ld hl, (collision_char_ptr)
        ld a, (collision_number)
        ld (hl), a
        ld a, '*'
        ld b, $01
        ld hl, TOKEN_BUF
        rst $08
        db F_OPEN
        jr c, .available
        rst $08
        db F_CLOSE
        ld a, (collision_number)
        cp '9'
        jr z, .no_suffix_position
        inc a
        ld (collision_number), a
        jr .try_number
.available:
        or a
        ret
.no_suffix_position:
        scf
        ret

; Permite letras, numeros, '-' y '_'; convierte letras a mayusculas.
sanitize_83_char:
        cp 'a'
        jr c, .not_lower
        cp 'z'+1
        jr nc, .not_lower
        sub 32
        ret
.not_lower:
        cp 'A'
        jr c, .check_digit
        cp 'Z'+1
        ret c
.check_digit:
        cp '0'
        jr c, .check_symbols
        cp '9'+1
        ret c
.check_symbols:
        cp '-'
        ret z
        cp '_'
        ret z
        ld a, '_'
        ret

flush_write_buffer:
        ld bc, (write_count)
        ld a, b
        or c
        ret z
        ld hl, DOWNLOAD_BUF
        ld a, (file_handle)
        rst $08
        db F_WRITE
        ret c
        xor a
        ld (write_count), a
        ld (write_count+1), a
        ld hl, DOWNLOAD_BUF
        ld (download_write_ptr), hl
        ret

get_id_slot:
        ld hl, RESULT_IDS
        ld de, ID_SLOT_SIZE
        jr add_slot_offset
get_name_slot:
        ld hl, RESULT_NAMES
        ld de, NAME_SLOT_SIZE
        jr add_slot_offset
get_size_slot:
        ld hl, RESULT_SIZES
        ld de, ID_SLOT_SIZE
add_slot_offset:
        or a
        ret z
.loop:
        add hl, de
        dec a
        jr nz, .loop
        ret

; Lee el tamano decimal apuntado por HL. El resultado se reduce a paginas
; de 256 bytes y distribuye cien umbrales mediante cociente y resto.
prepare_progress:
        xor a
        ld (size_value), a
        ld (size_value+1), a
        ld (size_value+2), a
.next_digit:
        ld a, (hl)
        or a
        jr z, .to_pages
        inc hl
        sub '0'
        jr c, .to_pages
        cp 10
        jr nc, .to_pages
        ld (size_digit), a
        ld a, (size_value)
        ld (size_temp), a
        ld a, (size_value+1)
        ld (size_temp+1), a
        ld a, (size_value+2)
        ld (size_temp+2), a
        xor a
        ld (size_value), a
        ld (size_value+1), a
        ld (size_value+2), a
        ld b, 10
.times_ten:
        call add_size_temp
        djnz .times_ten
        ld a, (size_value)
        ld c, a
        ld a, (size_digit)
        add a, c
        ld (size_value), a
        jr nc, .next_digit
        ld a, (size_value+1)
        inc a
        ld (size_value+1), a
        jr nz, .next_digit
        ld a, (size_value+2)
        inc a
        ld (size_value+2), a
        jr .next_digit
.to_pages:
        ld a, (size_value+1)
        ld l, a
        ld a, (size_value+2)
        ld h, a
        ld a, (size_value)
        or a
        jr z, .pages_ready
        inc hl                  ; ceil(tamano/256)
.pages_ready:
        ld (total_pages), hl
        ld de, 0
.divide_hundred:
        ld a, h
        or a
        jr nz, .subtract
        ld a, l
        cp 100
        jr c, .step_ready
.subtract:
        ld bc, 100
        or a
        sbc hl, bc
        inc de
        jr .divide_hundred
.step_ready:
        ld (progress_step_pages), de
        ld a, l                 ; Resto de total_pages / 100.
        ld (progress_remainder), a
        ld a, 99                ; floor((99+n*total)/100) = ceil(...)
        ld (progress_accumulator), a
        ld hl, 0
        ld (next_progress_page), hl
        xor a
        ld (progress_stage), a
        call advance_progress_threshold
        ret

add_size_temp:
        ld a, (size_temp)
        ld c, a
        ld a, (size_value)
        add a, c
        ld (size_value), a
        ld a, (size_temp+1)
        ld c, a
        ld a, (size_value+1)
        adc a, c
        ld (size_value+1), a
        ld a, (size_temp+2)
        ld c, a
        ld a, (size_value+2)
        adc a, c
        ld (size_value+2), a
        ret

progress_page_tick:
        ld hl, (download_pages)
        inc hl
        ld (download_pages), hl
.check_threshold:
        ld de, (next_progress_page)
        or a
        sbc hl, de
        ret c
        ld a, (progress_stage)
        cp 100
        ret nc
        inc a
        ld (progress_stage), a
        call print_progress_stage
        call advance_progress_threshold
        ld hl, (download_pages)
        jr .check_threshold     ; Puede avanzar varios % en una misma pagina.

advance_progress_threshold:
        ld hl, (next_progress_page)
        ld de, (progress_step_pages)
        add hl, de
        ld a, (progress_accumulator)
        ld c, a
        ld a, (progress_remainder)
        add a, c
        cp 100
        jr c, .save
        sub 100
        inc hl
.save:
        ld (progress_accumulator), a
        ld (next_progress_page), hl
        ret

; Sustituye los cuatro caracteres finales de "  0%" usando cursor izquierda.
print_progress_stage:
        push af
        ld b, 4
.back:
        ld a, 8
        rst $10
        djnz .back
        pop af
        cp 100
        jr z, .hundred
        cp 10
        jr nc, .two_digits
        push af
        ld a, ' '
        rst $10
        ld a, ' '
        rst $10
        pop af
        add a, '0'
        rst $10
        jr .percent
.two_digits:
        ld b, '0'
.tens:
        sub 10
        jr c, .tens_ready
        inc b
        jr .tens
.tens_ready:
        add a, 10
        ld c, a
        ld a, ' '
        rst $10
        ld a, b
        rst $10
        ld a, c
        add a, '0'
        rst $10
.percent:
        ld a, '%'
        rst $10
        ret
.hundred:
        ld hl, txt_100
        jp print_string

progress_finish:
        ld a, (progress_stage)
        cp 100
        jr z, .newline
        ld a, 100
        ld (progress_stage), a
        call print_progress_stage
.newline:
        ld a, 13
        rst $10
        ret

; ============================================================================
; UART Y RESPUESTAS AT
; ============================================================================
init_divtiesus_hw:
        ld b, 2                 ; Evita una espera larga si TX esta bloqueado.
.attempt:
        push bc
        call flush_uart_rx_fast
        ld hl, cmd_ate0
        call esp_send_cmd_string
        jr c, .failed           ; No esperar respuesta si no pudo enviarse.
        call wait_ok_quick
.failed:
        pop bc
        ret nc
        djnz .attempt
        scf
        ret

esp_send_byte:
        push af
        push bc
        push de
        push hl
        ld e, a
        ld bc, ZXUNO_ADDR
        ld a, UART_STAT_REG
        out (c), a
        inc b
        ld hl, 5000
.wait:
        ld a, $7F
        in a, ($FE)
        rra
        jr nc, .abort
        in a, (c)
        bit 6, a
        jr z, .ready
        dec hl
        ld a, h
        or l
        jr nz, .wait
        jr .abort
.ready:
        dec b
        ld a, UART_DATA_REG
        out (c), a
        inc b
        ld a, e
        out (c), a
        ld b, 40
.delay:
        djnz .delay
        pop hl
        pop de
        pop bc
        pop af
        or a
        ret
.abort:
        pop hl
        pop de
        pop bc
        pop af
        scf
        ret

esp_read_raw:
        push bc
        push de
        ld de, 15000
        ld bc, ZXUNO_ADDR
        ld a, UART_STAT_REG
        out (c), a
        inc b
.wait:
        ld a, $7F
        in a, ($FE)
        rra
        jr nc, .break
        in a, (c)
        or a
        jp m, .ready
        dec de
        ld a, d
        or e
        jr nz, .wait
        pop de
        pop bc
        scf
        ret
.ready:
        dec b
        ld a, UART_DATA_REG
        out (c), a
        inc b
        in a, (c)
        pop de
        pop bc
        or a
        ret
.break:
        pop de
        pop bc
        scf
        ret

; Version sin preservacion de registros para el bucle de descarga. El llamador
; no necesita BC/DE y evita cuatro operaciones de pila por cada byte recibido.
esp_read_raw_fast:
        ld de, 15000
        ld bc, ZXUNO_ADDR
        ld a, UART_STAT_REG
        out (c), a
        inc b
.wait:
        ld a, $7F
        in a, ($FE)
        rra
        jr nc, .break
        in a, (c)
        or a
        jp m, .ready
        dec de
        ld a, d
        or e
        jr nz, .wait
        scf
        ret
.ready:
        dec b
        ld a, UART_DATA_REG
        out (c), a
        inc b
        in a, (c)
        or a
        ret
.break:
        scf
        ret

flush_uart_rx:
.loop:
        call esp_read_raw
        ret c
        jr .loop

; Vaciado rapido para el arranque: no incurre en el timeout de esp_read_raw.
; Termina tras un breve periodo sin datos y tiene un limite total de sondeos.
flush_uart_rx_fast:
        push af
        push bc
        push de
        push hl
        ld hl, 16384            ; Limite total, incluso si llegan datos sin parar.
        ld de, 512              ; Sondeos consecutivos sin datos.
.poll:
        ld bc, ZXUNO_ADDR
        ld a, UART_STAT_REG
        out (c), a
        inc b
        in a, (c)
        or a
        jp p, .idle
        dec b
        ld a, UART_DATA_REG
        out (c), a
        inc b
        in a, (c)               ; Descartar byte pendiente.
        ld de, 512
        jr .advance
.idle:
        dec de
        ld a, d
        or e
        jr z, .done
.advance:
        dec hl
        ld a, h
        or l
        jr nz, .poll
.done:
        pop hl
        pop de
        pop bc
        pop af
        or a
        ret

esp_send_cmd_string:
        ld a, (hl)
        or a
        ret z
        call esp_send_byte
        ret c
        inc hl
        jr esp_send_cmd_string

; Busca OK completo: no confunde la E de CONNECT con ERROR.
wait_ok:
        ld b, 20
        jr wait_ok_common
wait_ok_quick:
        ld b, 3
        jr wait_ok_common
wait_ok_long:
        ld b, 100
wait_ok_common:
.next:
        call esp_read_raw
        jr nc, .got
        djnz .next
        scf
        ret
.got:
        cp 'O'
        jr nz, .next
        call esp_read_raw
        jr c, .next
        cp 'K'
        jr nz, .next
        or a
        ret

send_number_bc:
        push bc
        push de
        push hl
        ld h, b
        ld l, c
        ld de, TOKEN_BUF
        ld bc, -10000
        call .digit
        ld bc, -1000
        call .digit
        ld bc, -100
        call .digit
        ld c, -10
        call .digit
        ld a, l
        add a, '0'
        ld (de), a
        inc de
        xor a
        ld (de), a
        ld hl, TOKEN_BUF
.skip:
        ld a, (hl)
        cp '0'
        jr nz, .send
        inc hl
        ld a, (hl)
        or a
        jr nz, .skip
        dec hl
.send:
        call esp_send_cmd_string
        pop hl
        pop de
        pop bc
        ret
.digit:
        ld a, '0'-1
.digit_loop:
        inc a
        add hl, bc
        jr c, .digit_loop
        sbc hl, bc
        ld (de), a
        inc de
        ret

; ============================================================================
; AUXILIARES
; ============================================================================
skip_spaces:
        ld a, (hl)
        cp ' '
        ret nz
        inc hl
        jr skip_spaces
copy_string:
        ld a, (hl)
        or a
        ret z
        ld (de), a
        inc hl
        inc de
        jr copy_string
print_string:
        ld a, (hl)
        or a
        ret z
        rst $10
        inc hl
        jr print_string
print_char_safe:
        cp 13
        jr z, .print
        cp 32
        ret c
        cp 127
        ret nc
.print:
        rst $10
        ret
echo_until_timeout:
.loop:
        call esp_read_raw
        ret c
        call print_char_safe
        jr .loop

; Extrae solo los dos valores entre comillas de AT+CIFSR.
; Respuesta esperada: +CIFSR:STAIP,"..." y +CIFSR:STAMAC,"...".
print_cifsr_info:
        call seek_raw_quote
        ret c
        ld hl, txt_ip_label
        call print_string
        call print_raw_quoted
        ret c
        ld a, 13
        rst $10
        call seek_raw_quote
        ret c
        ld hl, txt_mac_label
        call print_string
        call print_raw_quoted
        ret c
        ld a, 13
        rst $10
        or a
        ret

; Extrae el primer campo entre comillas de AT+CWJAP?: el SSID actual.
print_ssid_info:
        call seek_raw_quote
        ret c
        ld hl, txt_ssid_label
        call print_string
        call print_raw_quoted
        ret c
        ld a, 13
        rst $10
        or a
        ret

seek_raw_quote:
.loop:
        call esp_read_raw
        ret c
        cp '"'
        jr nz, .loop
        or a
        ret

print_raw_quoted:
.loop:
        call esp_read_raw
        ret c
        cp '"'
        ret z
        call print_char_safe
        jr .loop

trace_cmd:
        push hl
        ld a, '>'
        rst $10
        ld a, ' '
        rst $10
        pop hl
        push hl
.label:
        ld a, (hl)
        or a
        jr z, .label_done
        cp 13
        jr z, .label_done
        rst $10
        inc hl
        jr .label
.label_done:
        ld a, 13
        rst $10
        pop hl
        call esp_send_cmd_string
.wait:
        call esp_read_raw
        jr nc, .got
        djnz .wait
        ld a, 13
        rst $10
        ret
.got:
        ld b, 1                 ; Tras recibir datos, solo un timeout extra.
        call print_char_safe
        jr .wait

; ============================================================================
; ERRORES, SALIDA, VARIABLES Y CADENAS
; ============================================================================
show_usage:
        ld hl, txt_usage
        call print_string
        jp exit_error
show_help:
        ld a, $FF
        ld (SCR_CT), a
        ld hl, txt_help
        call print_string
        ld a, 18               ; FLASH off no puede ir dentro de una cadena
        rst $10                ; terminada en cero: el parametro tambien es 0.
        xor a
        rst $10
        ld a, 13
        rst $10
        jp exit_success
err_no_wifi:
        ld hl, txt_err_wifi
        call print_string
        jp exit_error
err_info:
        ld hl, txt_err_info
        call print_string
        jp exit_error
err_connect:
        ld hl, txt_err_connect
        call print_string
        jp exit_error
err_send:
        ld hl, txt_err_send
        call print_string
        jp exit_error
err_http:
        ld hl, txt_err_http
        call print_string
        jp exit_error
err_no_results:
        ld hl, txt_err_no_results
        call print_string
        jp exit_error
err_sd:
        ld a, (sd_error_stage)
        cp 1
        jr z, .open
        cp 2
        jr z, .write
        ld hl, txt_err_sd
        jr .show
.open:
        ld hl, txt_err_open
        jr .show
.write:
        ld hl, txt_err_write
.show:
        call print_string
        jp exit_error
exit_error:
exit_success:
        pop hl
        pop de
        pop bc
        pop af
        ret

request_length:     dw 0
ipd_remaining:      dw 0
selected_name_ptr:  dw 0
result_count:       db 0
selected_index:     db 0
header_state:       db 0
file_handle:        db 0
write_count:        dw 0
download_write_ptr: dw DOWNLOAD_BUF
download_byte_in_page: db 0
download_pages:     dw 0
total_pages:        dw 0
progress_step_pages: dw 1
next_progress_page: dw 1
progress_stage:     db 0
progress_remainder: db 0
progress_accumulator: db 0
size_value:         ds 3,0
size_temp:          ds 3,0
size_digit:         db 0
display_remaining:  db 0
display_machine:    db 0        ; 0=sin modelo, 1=48, 2=128.
display_column:     db 0
year_buffer:        ds 8,0
extension_dot_ptr:  dw 0
name_base_remaining: db 0
collision_char_ptr: dw 0
collision_number:   db 0
sd_error_stage:     db 0

cmd_ate0:           db "ATE0",13,10,0
cmd_gmr:            db "AT+GMR",13,10,0
cmd_cifsr:          db "AT+CIFSR",13,10,0
cmd_cwjap:           db "AT+CWJAP?",13,10,0
cmd_cwautoconn:      db "AT+CWAUTOCONN=1",13,10,0
cmd_rst:             db "AT+RST",13,10,0
cmd_cipclose:       db "AT+CIPCLOSE",13,10,0
cmd_cipmux:         db "AT+CIPMUX=0",13,10,0
cmd_domain:         db 'AT+CIPDOMAIN="zxdb.remysharp.com"',13,10,0
cmd_connect_http:   db 'AT+CIPSTART="TCP","zxdb.remysharp.com",80',13,10,0
cmd_cipsend:        db "AT+CIPSEND=",0

req_search_head:    db "GET /?s=",0
req_search_tail:    db "&cat=g HTTP/1.1",13,10
                    db "Host: zxdb.remysharp.com",13,10
                    db "User-Agent: ZXSpectrum-esxDOS",13,10
                    db "Connection: close",13,10,13,10,0
req_download_head:  db "GET /get/",0
req_download_tail:  db " HTTP/1.1",13,10
                    db "Host: zxdb.remysharp.com",13,10
                    db "User-Agent: ZXSpectrum-esxDOS",13,10
                    db "Connection: close",13,10,13,10,0

txt_trace:          db "ZXDB Remy HTTP diagnostics",13,0
; GRAPHICS 8 (codigo 143) forma una banda de bloques de 32 columnas.
txt_search_header:  db 143,143,143,143,143,143,143,143
                    db " SEARCH RESULTS "
                    db 143,143,143,143,143,143,143,143,13,13,0
txt_network_connected: db "Network status: Connected",13,0
txt_network_not_connected: db "Network status: Not connected",13
                    db "If WIFI is not configured:",13
                    db "Run .wconf",13,0
txt_reconnecting_wifi: db "Reconnecting WIFI...",13,0
txt_ssid_label:     db "SSID: ",0
txt_ip_label:       db "IP: ",0
txt_mac_label:      db "MAC: ",0
txt_type_open:      db " ",0
txt_type_unknown:   db "???",0
txt_details_indent: db "   ",0
txt_machine_48:     db "48",0
txt_machine_128:    db "128",0
txt_year_open:      db " (",0

; Bitmaps 8x8 usados por el dibujado directo en pantalla.
bracket_open_bitmap:
                    db $38,$20,$20,$20,$20,$20,$20,$38
bracket_close_bitmap:
                    db $38,$08,$08,$08,$08,$08,$08,$38
txt_select:         db 13,"Select 1-9/0 (BREAK cancels): ",0
txt_cancelled:      db "Cancelled",13,0
txt_saving:         db "Saving: ",0
txt_progress:       db "Progress:   0%",0
txt_100:            db "100%",0
txt_download_ok:    db "Download completed",13,0
txt_usage:          db "Usage: .ZXDB -h | -i | -s \"game name\"",13,0
txt_help:           db ".ZXDB - ZXDB game search",13,13
                    db "Usage:",13
                    db "  .ZXDB -i",13
                    db "    Show Wi-Fi information.",13
                    db "  .ZXDB -s \"game name\"",13
                    db "    Search downloadable games",13
                    db "    (TAP, TZX, Z80, etc...)",13,13
                    db "Results show the game title,",13
                    db "48/128 model when known,",13
                    db "file type (TAP, TZX, Z80,",13
                    db "etc...) and year.",13
                    db "Press 1-9 or 0 to download.",13
                    db "Press BREAK to cancel.",13,13
                    db "Thanks to Remy Sharp.",13
                    db ".ZXDB is based on the",13
                    db "zxdb.remysharp.com API.",13,13
                    db "Visit ",18,1,"www.retromaquinas.com",0
txt_err_hw:         db "Error: UART doesn't respond",13,0
txt_err_wifi:       db "Error: No WIFI network. Run .wconf",13,0
txt_err_info:       db "Error: incomplete network information",13,0
txt_err_connect:    db "Error: cannot connect to zxdb.remysharp.com",13,0
txt_err_send:       db "Error: CIPSEND",13,0
txt_err_http:       db "Error: invalid HTTP response",13,0
txt_err_no_results: db "No results found",13,0
txt_err_sd:         db "Error saving to SD card",13,0
txt_err_open:       db "Error: cannot create file",13,0
txt_err_write:      db "Error: failed to write file",13,0