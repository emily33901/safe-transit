module apps

import time
import sync2
import sync2.atomic3
import sync.atomic2
import sync
import net

pub struct RelayApp {
	args                Args
mut:
	pool                 &sync2.TaskPool
	listen               &net.TcpListener = voidptr(0)
	client_mutex         sync.Mutex
	client_conns         map[int]&net.TcpConn
	endpoint_conn        &net.TcpConn = voidptr(0)
	endpoint_write_queue chan Packet
	last_client_index    int
	stats                &Stats
}

pub fn new_relay(a Args) &RelayApp {
	return &RelayApp{
		args: a
		pool: sync2.new_pool_processor({
			maxjobs: max_jobs
		})
		client_mutex: sync.new_mutex()
		stats: &Stats{}
		endpoint_write_queue: chan Packet{cap:max_write_queue_size}
	}
}

fn (mut app RelayApp) queue_endpoint_data(data []byte) {
	app.endpoint_write_queue <- packet_from_data(data)
	atomic2.add_u64(&app.stats.behind, 1)
}

fn (mut app RelayApp) disconnect_client(id int) ? {
	// queue drop packet to be sent
	app.queue_endpoint_data(build_drop_packet(id))

	app.client_mutex.@lock()
	defer {
		app.client_mutex.unlock()
	}
	if id in app.client_conns.keys() {
		// if in the client list then remove
		mut c := app.client_conns[id]
		c.close()?
		app.client_conns.delete_1(id)
	} 
	return none
}

[inline]
fn (mut app RelayApp) client(id int) ?&net.TcpConn {
	app.client_mutex.@lock()
	defer {
		app.client_mutex.unlock()
	}
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
	app.endpoint_write_queue.close()
}

struct RelayClientFrameTaskContext {
	id     int
mut:
	buffer []byte
}

[inline]
fn (mut app RelayApp) client_frame(id int, mut buffer []byte) ? {
	mut packet_header := &PacketHeader(buffer.data)
	mut c := app.client(id) or {
		return error('No client with id exists anymore')
	}
	// Read into the buffer after the space for the packet header
	read := c.read(mut buffer[header_size..]) or {
		// Nothing to read from this client so move on
		if errcode == net.err_timed_out_code {
			return none
		}
		println('read: [$id] $errcode $err: Disconnecting client')
		app.disconnect_client(id)?
		return error('Disconnection')
	}
	if read == 0 {
		return none
	}
	atomic2.add_u64(&app.stats.frontside_read, read)
	// Setup the packet header for this client
	packet_header.id = id
	packet_header.size = read
	packet_header.@type = .data

	// queue this data to be sent to endpoint
	// TODO really dont clone these things its abhorent
	app.queue_endpoint_data(buffer[..header_size+read].clone())

	return none
}

[inline]
fn (mut app RelayApp) endpoint_write_frame() ? {
	for {
		packet := <-app.endpoint_write_queue or {
			if app.pool.has_shutdown() {
				return none
			}
		}

		packet.check()
		mut sent := 0
		for sent != packet.data.len {
			sent += app.endpoint_conn.write(packet.data) or {
				if errcode == net.err_timed_out_code {
					// println('endpoint_write_frame: blocked')
					continue
				}
				// Something tragic happened...
				return error_with_code(err, errcode)
			}
		}

		atomic2.add_u64(&app.stats.backside_wrote, packet.data.len)

		packet.free()
		atomic2.sub_u64(&app.stats.behind, 1)
	}
	return none
}

struct RelayEndpointFrameTaskContext {
mut:
	buffer []byte
}

[inline]
fn (mut app RelayApp) endpoint_frame(mut buffer []byte) ? {
	mut packet_header := &PacketHeader(buffer.data)
	for {
		// First just read the header so we know how much to then read
		mut read := 0
		for read != header_size {
			read += app.endpoint_conn.read(mut buffer[read..header_size]) or {
				if errcode == net.err_timed_out_code {
					// Nothing to read right now
					continue
				}
				// Something tragic happened...
				return error_with_code(err, errcode)
			}
		}
		id := packet_header.id
		size := packet_header.size

		if int(packet_header.@type) > 2 {
			println('endpoint: Invalid packet type ${u32(packet_header.@type)}')
			return error('invalid packet type from endpoint: ${u32(packet_header.@type)}')
		}

		match packet_header.@type {
			.data {
				if size == 0 {
					println('endpoint: [$id]: 0-size packet')
					return none
				}
				// Read all bytes of this payload into the buffer
				read = 0
				for read < size {
					read += app.endpoint_conn.read(mut buffer[header_size+read..header_size + size]) or {
						if errcode == net.err_timed_out_code {
							continue
						}
						// Something tragic happened...
						return error_with_code(err, errcode)
					}
				}
				atomic2.add_u64(&app.stats.backside_read, size + header_size)
				// If the id is not in our list then just chuck the data away
				// and tell the endpoint to not send us anymore please
				if id !in app.client_conns {
					println('endpoint: [$id]: doesnt exist')
					app.disconnect_client(id)?
					continue
				}
				// Send data back to client
				for {
					app.client_conns[id].write(buffer[header_size..header_size + size]) or {
						if errcode == net.err_timed_out_code {
							// TODO dont do this it will block everyone else
							continue
						}
						println('write: [$id] $errcode $err: Disconnecting client')
						app.disconnect_client(id)?
						break
					}
					break
				}
				atomic2.add_u64(&app.stats.frontside_wrote, size + header_size)
			}
			.drop {
				println('drop: [$id]: Dropping by request')
				app.disconnect_client(id)?
			}
		}
		if app.pool.has_shutdown() {
			return none
		}
	}
	println('yielded')
	return none
}

[inline]
fn (mut app RelayApp) accept_frame() {
	// Try and accept a connection
	mut conn := app.listen.accept() or {
		// no connection - cleanup for the compiler
		err.free()
		return
	}

	conn.set_read_timeout(net.no_timeout)
	conn.set_write_timeout(net.no_timeout)

	// We got a connection
	// This is sync becuase we are the only task to touch this
	app.last_client_index++
	println('connect: [$app.last_client_index] new')
	id := app.last_client_index

	app.client_mutex.@lock()
	app.client_conns[id] = conn
	app.client_mutex.unlock()

	app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
		mut a := &RelayApp(t.item)
		mut ctx := &RelayClientFrameTaskContext(t.context)
		// sync2.set_thread_desc(sync2.thread_id(), 'client_frame[$ctx.id]')
		a.client_frame(ctx.id, mut ctx.buffer) or {
			// Error happened so we are done with this client
			// TODO we need to free memory here
			println('client: $err $errcode: finished')
			return .finished
		}
		return .yield
	}, app, voidptr(&RelayClientFrameTaskContext{
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
			app.endpoint_conn.sock.set_option_int(.send_buf_size, tcp_buffer_size)?
			app.endpoint_conn.sock.set_option_int(.recieve_buf_size, tcp_buffer_size)?

			break
		}
		println('Got endpoint - pumping!')
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &RelayApp(t.item)
			// sync2.set_thread_desc(sync2.thread_id(), 'endpoint_write_frame')
			a.endpoint_write_frame() or {
				a.shutdown_pool(err, errcode)
				println('endpoint_write_frame: $err $errcode: finished')
				return .finished
			}
			return .yield
		}, app, voidptr(0))
		// Task to listen for new clients
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &RelayApp(t.item)
			// println('accept: frame')
			// sync2.set_thread_desc(sync2.thread_id(), 'accept_frame')
			a.accept_frame()
			return .yield
		}, app, voidptr(0))
		// Task to listen to endpoint
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &RelayApp(t.item)
			mut ctx := &RelayEndpointFrameTaskContext(t.context)
			// println('endpoint: frame')
			// sync2.set_thread_desc(sync2.thread_id(), 'endpoint_frame')
			a.endpoint_frame(mut ctx.buffer) or {
				// Endpoint task finished so we need to reconnect anyway
				// say that we are shutting down
				a.shutdown_pool(err, errcode)
				// TODO we need to free memory here
				println('endpoint: $err $errcode: finished')
				return .finished
			}
			return .yield
		}, app, voidptr(&RelayEndpointFrameTaskContext{
			buffer: new_data_buffer()
		}))
		// Task for stats
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			// sync2.set_thread_desc(sync2.thread_id(), 'stats_frame')
			time.sleep(1)
			mut a := &RelayApp(t.item)
			a.stats.print_stats(a.client_conns.len)
			return .yield
		}, app, voidptr(0))
		// Work and wait for shutdown
		app.pool.work()
		println('run: pool shutdown finished')
		// Cleanup any connections that might have existed
		app.endpoint_conn.close() or {
		}
		for id, mut c in app.client_conns {
			c.close() or {
			}
			app.client_conns.delete_1(id)
		}
		println('relay: restarting')
	}
	return none
}
