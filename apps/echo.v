module apps

import emily33901.net
import time

pub fn echo(a Args) ? {
	println('Echo started, listening on $a.app_port ...')

	mut listen := net.listen_tcp(a.app_port) or {
		panic(err)
	}
	listen.set_accept_timeout(1 * time.nanosecond)

	mut conns := map[string]net.TcpConn
	mut last_id := 0
	mut buffer := []byte { len: 4096 }
	for {
		if new_sock := listen.accept() {
			last_id++
			println('New $last_id')
			conns[last_id.str()] = new_sock
		}

		for id, s in conns {
			read := s.read_into(mut buffer) or {
				if errcode == net.err_read_timed_out_code {
					continue
				}

				0
			}

			if read == 0 {
				println('Dropping $id')
				s.close()
				conns.delete(id)
				continue
			}

			s.write(buffer[..read]) or {
				println('Dropping $id')
				s.close()
				conns.delete(id)
			}
		}
	}
}