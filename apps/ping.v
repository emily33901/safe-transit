module apps

import emily33901.net
import time

pub fn ping(a Args) ? {
	println('Ping started, connecting to $a.relay_ip:$a.app_port ...')

	to_send := 'Ping!'.repeat(300)
	to_send_bytes := to_send.bytes()
	mut buf := []byte{len: 4096 }

	for {
		println('(re)connecting...')
		conn := net.dial_tcp('$a.relay_ip:$a.app_port') or {
			panic(err)
		}

		for {
			for  {
				read := conn.read_into(mut buf) or {
					break
				}

				if read == 0 { break }

				println('Got ($read) "${string(buf[..read])}"')			
			}

			conn.write(to_send_bytes)?
			time.sleep_ms(1)
		}
	}
}