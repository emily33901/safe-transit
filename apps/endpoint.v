module apps

import emily33901.net

pub struct EndpointApp {
	args Args
	buffer []byte
mut:
	loopback_conns map[string]net.TcpConn
	relay_conn net.TcpConn
}

pub fn new_endpoint(a Args) EndpointApp {
	return EndpointApp {
		args: a
		buffer: []byte{ len: data_size, cap: data_size + header_size, init: 0 }
	}
}

fn (mut app EndpointApp) disconnect_loopback(id string) ? {
	if id in app.loopback_conns.keys() {
		c := app.loopback_conns[id]
		c.close()?
		app.loopback_conns.delete(id)

		send_drop_packet(app.relay_conn, id.int())
	}

	return none
}

fn (mut app EndpointApp) frame() ? {
	// TODO probably stackalloc
	mut buffer := app.buffer
	mut packet_header := &PacketHeader(buffer.data)

	// Read data from the relay
	for {
		// First just read the header so we know how much to then read
		mut read := app.relay_conn.read_into(mut buffer[..header_size]) or {
			if errcode == net.err_read_timed_out_code {
				// Nothing to read right now
				break
			}
			// Something tragic happened...
			return error_with_code(err, errcode)
		}

		id := '$packet_header.id'
		size := packet_header.size

		match packet_header.@type {
			.data {
				// Read all bytes of this payload into the buffer
				read = 0
				for read < size {
					read += app.relay_conn.read_into(mut buffer[header_size..header_size+size]) or {
						if errcode == net.err_read_timed_out_code {
							continue
						}
						// Something tragic happened...
						return error_with_code(err, errcode)
					}
				}

				if read == 0 { 
					id.free()
					return none 
				}

				if id !in app.loopback_conns {
					// Create a new loopback connection
					println('connect: [$id] new')
					app.loopback_conns[id] = net.dial_tcp('127.0.0.1:$app.args.app_port')?
					println('connect: [$id] connected')
				}

				// Send data back to client
				for {
					app.loopback_conns[id].write(buffer[header_size..header_size+size]) or {
						if errcode == net.err_write_timed_out_code {
							// TODO dont do this it will block everyone else
							continue
						}

						println('write: [$id] $errcode $err: Disconnecting loopback')
						app.disconnect_loopback(id)

						break
					}
					break
				}
			}
			.drop {
				println('drop: [$id]: Dropping by request')
				app.disconnect_loopback(id)
			}
		}

		id.free()
	}

	// check loopback sockets for data
	for id, c in app.loopback_conns {
		// Read into the buffer after the space for the packet header
		read := c.read_into(mut buffer[header_size..]) or {
			// Nothing to read from this client so move on
			if errcode == net.err_read_timed_out_code {
				continue
			}

			println(' read: [$id] $errcode $err: Disconnecting loopback')
			app.disconnect_loopback(id)

			continue
		}

		if read == 0 { continue }

		// Setup the packet header for this client
		packet_header.id = id.int()
		packet_header.size = read
		packet_header.@type = .data

		// Send the data on its way
		for {
			app.relay_conn.write(buffer[..header_size+read]) or {
				if errcode == net.err_write_timed_out_code {
					// TODO dont do this it will block everyone else
					continue
				}
				// Something tragic happened...
				return error_with_code(err, errcode)
			}
			break
		}
	}

	return none
}

pub fn (app &EndpointApp) run() ? {
	println('Endpoint starting - listening to app on $app.args.app_port and connecting to relay on $app.args.relay_ip')
	
	for {
		for {
			println('Waiting for relay...')
			app.relay_conn = net.dial_tcp('$app.args.relay_ip') or {
				println('$errcode $err')
				continue
			}
			break
		}

		println('Got relay - pumping!')

		for {
			app.frame() or {
				println("frame: $errcode $err: restarting app")
				break
			}
		}

		// Cleanup any connections that might have existed
		app.relay_conn.close() or { }
		for id, c in app.loopback_conns {
			c.close() or { }
			app.loopback_conns.delete(id)
		}
	}

	return none
}