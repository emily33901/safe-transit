module apps

import net
import time

pub fn ping(a Args) ? {
	println('Ping started, connecting to $a.relay_ip:$a.app_port ...')
	to_send := 'AAA'.repeat(100)
	to_send_bytes := to_send.bytes()
	println('$to_send_bytes.len')
	mut buf := []byte{len: 4096}
	for {
		println('(re)connecting...')
		mut connections := []&net.TcpConn{len: a.count}
		for i in 0 .. a.count {
			mut new_conn := net.dial_tcp('$a.relay_ip:$a.app_port') or {
				panic(err)
			}
			new_conn.set_read_timeout(net.no_timeout)
			new_conn.set_write_timeout(net.no_timeout)
			connections[i] = &net.TcpConn(voidptr(new_conn))
			println('$i connected')
		}
		mut to_remove := []int{}
		for {
			for i, mut conn in connections {
				for {
					read := conn.read(mut buf) or {
						break
					}
					if read == 0 {
						break
					}
					// text := 'Got ($read)'
					// println(text)
					// text.free()
				}
				conn.write(to_send_bytes) or {
					if errcode != net.err_timed_out_code {
						println('$i broke $errcode $err')
						to_remove << i
					}
					break
				}
			}
			if to_remove.len > 0 {
				for i in to_remove {
					connections.delete(i)
				}
				to_remove.clear()
			}
			// time.sleep_ms(1)
			if connections.len == 0 {
				println('restarting (all connections were dropped)')
				break
			}
		}
	}
	return
}
