module apps

import time
import sync2
import sync2.atomic3
import sync.atomic2
import emily33901.net

struct Stats {
	frontside_read u64
	frontside_wrote u64

	backside_read u64
	backside_wrote u64
}

pub struct RelayApp {
	args Args
	buffer []byte
mut:
	pool &sync2.YieldingPoolProcessor
	listen net.TcpListener
	client_mutex &sync2.Mutex
	client_conns map[string]net.TcpConn
	endpoint_mutex &sync2.Mutex
	endpoint_conn net.TcpConn
	last_client_index int
	stats &Stats
}

pub fn new_relay(a Args) RelayApp {
	return RelayApp {
		args: a
		buffer: []byte{ len: data_size, cap: data_size + header_size, init: 0 }
		pool: sync2.new_pool_processor({ maxjobs: 0 })
		client_mutex: sync2.new_mutex()
		endpoint_mutex: sync2.new_mutex()
		stats: &Stats {}
	}
}

fn (mut app RelayApp) print_stats() {
	frontside_read := u64(atomic3.atomic_exchange(&app.stats.frontside_read, 0)) / 1024
	frontside_wrote := u64(atomic3.atomic_exchange(&app.stats.frontside_wrote, 0)) / 1024

	backside_read := u64(atomic3.atomic_exchange(&app.stats.backside_read, 0)) / 1024
	backside_wrote := u64(atomic3.atomic_exchange(&app.stats.backside_wrote, 0)) / 1024

	println('stats: frontside: ${frontside_read}Kbit/${frontside_wrote}Kbit')
	println('stats:  backside: ${backside_read}Kbit/${backside_wrote}Kbit')
	println('stats:      neck: ${backside_read}Kbit/${frontside_wrote}Kbit ${frontside_read}Kbit/${backside_wrote}Kbit')
}

fn (mut app RelayApp) disconnect_client(id string) ? {
	app.client_mutex.lock()
	defer { app.client_mutex.unlock() }

	if id in app.client_conns.keys() {
		c := app.client_conns[id]
		c.close()?
		app.client_conns.delete(id)
	
		send_drop_packet(app.endpoint_conn, id.int())
	}

	return none
}

[inline]
fn (mut app RelayApp) client(id string) ?net.TcpConn {
	app.client_mutex.lock()
	defer { app.client_mutex.unlock() }
	if id in app.client_conns {
		return app.client_conns[id]
	}
	return none
}

fn (mut app RelayApp) shutdown_pool(err string, code int) {
	println('shutdown: $code $err: shutting down pool')
	app.endpoint_conn.close() or { 
		println('shutdown: $err $errcode: shutdown conn failed')
	}
	app.pool.shutdown()
}

struct RelayClientFrameTaskContext {
	id string
	buffer []byte
}

[inline]
fn (mut app RelayApp) client_frame(id string, buffer []byte) ? {
	packet_header := &PacketHeader(buffer.data)
	c := app.client(id) or {
		return error('No client with id exists anymore')
	}
	// Read into the buffer after the space for the packet header
	read := c.read_into(mut buffer[header_size..]) or {
		// Nothing to read from this client so move on
		if errcode == net.err_read_timed_out_code {
			return none
		}

		println('read: [$id] $errcode $err: Disconnecting client')
		app.disconnect_client(id)

		return error('Disconnection')
	}

	if read == 0 { return none }
	// println('read: [$id]: $read')

	atomic2.add_u64(&app.stats.frontside_read, read)

	// Setup the packet header for this client
	packet_header.id = id.int()
	packet_header.size = read
	packet_header.@type = .data
	// Send the data on its way
	// Make sure we have the endpoint mutex so we dont screw up
	// someone elses packet
	app.endpoint_mutex.lock()
	defer { app.endpoint_mutex.unlock() }
	for {
		app.endpoint_conn.write(buffer[..header_size+read]) or {
			if errcode == net.err_write_timed_out_code {
				// sync2.thread_yield()
				continue
			}
			// Something tragic happened...
			app.shutdown_pool(err, errcode)
			return error_with_code(err, errcode)
		}
		break
	}

	atomic2.add_u64(&app.stats.backside_wrote, header_size+read)

	return none
}

struct RelayEndpointFrameTaskContext {
	buffer []byte
}

[inline]
fn (mut app RelayApp) endpoint_frame(buffer []byte) ? {
	mut packet_header := &PacketHeader(buffer.data)

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
		id := packet_header.id.str()
		size := packet_header.size
		match packet_header.@type {
			.data {
				if size == 0 {
					println('endpoint: [$id]: 0-size packet')
					id.free()
					return none
				}

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

				atomic2.add_u64(&app.stats.backside_read, size+header_size)

				// If the id is not in our list then just chuck the data away
				// and tell the endpoint to not send us anymore please
				if id !in app.client_conns {
					println('endpoint: [$id]: doesnt exist')
					app.disconnect_client(id)
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
				atomic2.add_u64(&app.stats.frontside_wrote, size+header_size)
				id.free()
			}
			.drop {
				println('drop: [$id]: Dropping by request')
				app.disconnect_client(id)
			}
		}
	}

	return none
}

[inline]
fn (mut app RelayApp) accept_frame() {
	// Try and accept a connection
	conn := app.listen.accept() or {
		// no connection - cleanup for the compiler
		err.free()
		return
	}

	// We got a connection

	// This is sync becuase we are the only task to touch this
	app.last_client_index++
	println('connect: [$app.last_client_index] new')

	id := '$app.last_client_index'
	
	app.client_mutex.lock()
	app.client_conns[id] = conn
	app.client_mutex.unlock()

	app.pool.add_task(fn (p &sync2.YieldingPoolProcessor, t &sync2.Task, tid int) sync2.TaskResult {
		mut a := &RelayApp(t.item)
		mut ctx := &RelayClientFrameTaskContext(t.context)
		a.client_frame(ctx.id, ctx.buffer) or {
			// Error happened so we are done with this client
			// TODO we need to free memory here
			println('client: $err $errcode: finished')
			return .finished
		}
		return .yield
	}, app, voidptr(&RelayClientFrameTaskContext {
		id: id
		buffer: new_data_buffer()
	}))
}

pub fn (mut app RelayApp) run() ? {
	println('Relay starting - listening to clients on $app.args.app_port and endpoint on $app.args.relay_port')

	// Create listen sockets for the endpoint and clients
	app.listen = net.listen_tcp(app.args.app_port)?
	app.listen.set_accept_timeout(500 * time.millisecond)
	
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

		// Task to listen for new clients
		app.pool.add_task(
			fn (p &sync2.YieldingPoolProcessor, t &sync2.Task, tid int) sync2.TaskResult {
				mut a := &RelayApp(t.item)
				// println('accept: frame')
				a.accept_frame()
				return .yield
			}, app, voidptr(0)
		)

		// task to listen to endpoint
		app.pool.add_task(
			fn (p &sync2.YieldingPoolProcessor, t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &RelayApp(t.item)
			mut ctx := &RelayEndpointFrameTaskContext(t.context)
			// println('endpoint: frame')
			a.endpoint_frame(ctx.buffer) or {
				// Error happened so we are done with this client
				// TODO we need to free memory here
				println('endpoint: $err $errcode: finished')
				return .finished
			}
			return .yield
		}, app, voidptr(&RelayEndpointFrameTaskContext {
			buffer: new_data_buffer()
		}))

		app.pool.add_task(
			fn (p &sync2.YieldingPoolProcessor, t &sync2.Task, tid int) sync2.TaskResult {
				time.sleep(2)
				mut a := &RelayApp(t.item)
				a.print_stats()

				return .yield
			}, app, voidptr(0)
		)

		// Work and wait for shutdown
		app.pool.work()

		println('run: pool shutdown finished')

		// Cleanup any connections that might have existed
		app.endpoint_conn.close() or { }
		for id, c in app.client_conns {
			c.close() or { }
			app.client_conns.delete(id)
		}
	}

	return none
}