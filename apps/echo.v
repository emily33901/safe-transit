module apps

import net

fn accept_connection(mut listen &net.TcpListener) ?&net.TcpConn {
	mut new_conn := listen.accept() or {
		return none
	}

	new_conn.set_read_timeout(net.no_timeout)
	new_conn.set_write_timeout(net.no_timeout)
	// TODO set buffer sizez properly here
	return new_conn
}

pub fn echo(a Args) ? {
	println('Echo started, listening on $a.app_port ...')
	mut listen := net.listen_tcp(a.app_port) or {
		panic(err)
	}
	listen.set_accept_timeout(net.no_timeout)
	mut conns := map[int]&net.TcpConn{}
	mut last_id := 0
	mut buffer := []byte{len: 10000}
	for {
		if new_conn := accept_connection(mut listen) {
			last_id++
			println('New $last_id')

			conns[last_id] = new_conn
		}
		for id, mut s in conns {
			read := s.read(mut buffer) or {
				if errcode == net.err_timed_out_code {
					continue
				}
				0
			}
			if read == 0 {
				println('Dropping $id')
				s.close()?
				conns.delete_1(id)
				continue
			}
			mut wrote := 0
			for wrote != read {
				wrote += s.write(buffer[wrote..read]) or {
					if errcode == net.err_timed_out_code {
						break
					}
					println('Dropping $id')
					s.close()?
					conns.delete_1(id)
					break
				}
			}

		}
	}
	return
}
