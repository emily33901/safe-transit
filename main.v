module main

import emily33901.net
import os
import flag
import time

struct Args {
	relay_ip   string
	relay_port int
	app_port   int
}

enum PacketType {
	// Regular data packet
	data
	// A client that was added from a data packet needs to be 
	// decked, checked and wrecked
	drop
}

struct PacketHeader {
mut:
	// Type of this packet
	@type PacketType
	// Id of the client who sent it
	id int
	// Size of the following payload (should be 1..data_size)
	size int
}

const (
	data_size = 1024
	header_size = int(sizeof(PacketHeader))
)

fn send_drop_packet(conn net.TcpConn, id int) ? {
	// Tell the endpoint this client is gone
	// so that it doesnt keep sending us data we will
	// just throw away
	p := PacketHeader {
		@type: .drop
		id: id
		size: 0
	}
	// Fake a buffer out of it
	b := array {data: &p, len: header_size}
	conn.write(b)?
	return none
}

struct RelayApp {
	args Args
	buffer []byte
mut:
	client_conns map[string]net.TcpConn
	listen net.TcpListener
	endpoint_listen net.TcpListener
	endpoint_conn net.TcpConn
	last_client_index int
}

fn new_relay_app(a Args) RelayApp {
	return RelayApp {
		args: a
		buffer: []byte{ len: data_size, cap: data_size + header_size, init: 0 }
	}
}

fn (mut app RelayApp) disconnect_client(id string) ? {
	if id in app.client_conns.keys() {
		c := app.client_conns[id]
		c.close()?
		app.client_conns.delete(id)
	
		send_drop_packet(app.endpoint_conn, id.int())
	}

	return none
}

fn (mut app RelayApp) frame() ? {
	// TODO probably stackalloc
	mut buffer := app.buffer
	mut packet_header := &PacketHeader(buffer.data)

	// Try and accept a connection
	if conn := app.listen.accept() {
		app.last_client_index++
		println('connect: [$app.last_client_index] new')
		app.client_conns[app.last_client_index.str()] = conn
	}
	// Read data from the endpoint
	for {
		// First just read the header so we know how much to then read
		mut read := app.endpoint_conn.read_into(mut buffer[..header_size]) or {
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
					read += app.endpoint_conn.read_into(mut buffer[header_size..header_size+size]) or {
						if errcode == net.err_read_timed_out_code {
							continue
						}
						// Something tragic happened...
						return error_with_code(err, errcode)
					}
				}
				// If the id is not in our list then just chuck the data away
				if id !in app.client_conns {
					id.free()
					continue
				}
				// Send data back to client
				for {
					app.client_conns[id].write(buffer[header_size..header_size+size]) or {
						if errcode == net.err_write_timed_out_code {
							// TODO dont do this it will block everyone else
							continue
						}
						println('write: [$id] $errcode $err: Disconnecting client')
						app.disconnect_client(id)
						break
					}
					break
				}
				id.free()
			}
			.drop {
				println('drop: [$id]: Dropping by request')
				app.disconnect_client(id)
			}
		}
	}

	// Try and get some data from clients and send it to the backend
	for id, c in app.client_conns {
		// Read into the buffer after the space for the packet header
		read := c.read_into(mut buffer[header_size..]) or {
			// Nothing to read from this client so move on
			if errcode == net.err_read_timed_out_code {
				continue
			}

			println(' read: [$id] $errcode $err: Disconnecting client')
			app.disconnect_client(id)

			continue
		}

		// Setup the packet header for this client
		packet_header.id = id.int()
		packet_header.size = read
		packet_header.@type = .data

		// Send the data on its way
		for {
			app.endpoint_conn.write(buffer[..header_size+read]) or {
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

fn (mut app RelayApp) run() ? {
	println('Relay starting - listening to clients on $app.args.app_port and endpoint on $app.args.relay_port')

	// Create listen sockets for the endpoint and clients
	app.listen = net.listen_tcp(app.args.app_port)?
	app.listen.set_accept_timeout(1 * time.nanosecond)
	
	mut endpoint_listen := net.listen_tcp(app.args.relay_port)?
	endpoint_listen.set_accept_timeout(1 * time.second)
	
	for {
		// Wait for the endpoint to connect
		println('Waiting for endpoint...')
		for {
			app.endpoint_conn = endpoint_listen.accept() or {
				println('Waiting for endpoint...')
				continue
			}
			break
		}
	
		println('Got endpoint - pumping!')

		for {
			app.frame() or {
				println("frame: $errcode $err: restarting app")
				break
			}
		}

		// Cleanup any connections that might have existed
		app.endpoint_conn.close() or { }
		for id, c in app.client_conns {
			c.close() or { }
			app.client_conns.delete(id)
		}
	}

	return none
}

struct EndpointApp {
	args Args
	buffer []byte
mut:
	loopback_conns map[string]net.TcpConn
	relay_conn net.TcpConn
}

fn new_endpoint_app(a Args) EndpointApp {
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

fn (app &EndpointApp) run() ? {
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

fn echo_app(a Args) ?  {
	println('Echo started, listening on $a.app_port ...')

	listen := net.listen_tcp(a.app_port) or {
		panic(err)
	}

	mut conns := map[string]net.TcpConn
	mut last_id := 0
	mut buffer := []byte {len: 100}
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

fn ping_app(a Args) ? {
	println('Ping started, connecting to $a.relay_ip:$a.app_port ...')

	to_send := 'Ping!'
	to_send_bytes := to_send.bytes()
	mut buf := []byte{len: 100}

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

				println('Got ($read) "${string(buf[..read])}"')			
			}

			conn.write(to_send_bytes)?
			time.sleep_ms(10)
		}
	}
}

fn main() {
	fp := flag.new_flag_parser(os.args)
	fp.application('safe-transit')
	fp.version('v0.0.0')
	fp.description('Tcp relay')
	fp.skip_executable()
	
	// Apps
	is_echo := fp.bool('echo', `c`, false, 'echo app')
	is_ping := fp.bool('ping', `g`, false, 'ping app')
	is_relay := fp.bool('relay', `r`, false, 'Run relay app')
	is_endpoint := fp.bool('endpoint', `e`, false, 'Run endpoint app')

	// config
	relay_ip := fp.string('ip', `i`, '', 'IP of the relay (if running in endpoint mode)')
	relay_port := fp.int('relay_port', `p`, 7778, 'Port of the relay channel (if running in relay mode)')
	app_port := fp.int('app_port', `a`, 7777, 'Port of the application')
	
	_ := fp.finalize() or {
		println(err)
		println(fp.usage())
		return
	}

	apps := int(is_relay) + int(is_endpoint) + int(is_echo) + int(is_ping)
	if apps > 1 || apps == 0 {
		println(fp.usage())
		println('Can only be one app at a time!')
		return
	}

	if is_echo {
		echo_app(Args{
			relay_port: relay_port
			app_port: app_port
			relay_ip: relay_ip
		})?
	}

	if is_ping {
		ping_app(Args{
			relay_port: relay_port
			app_port: app_port
			relay_ip: relay_ip
		})?
	}

	if is_relay {
		mut app := new_relay_app(Args{
			relay_port: relay_port
			app_port: app_port
			relay_ip: relay_ip
		})
		app.run()?
	}
	
	if is_endpoint {
		mut app := new_endpoint_app(Args{
			relay_port: relay_port
			app_port: app_port
			relay_ip: relay_ip
		})
		app.run()?
	}
}
