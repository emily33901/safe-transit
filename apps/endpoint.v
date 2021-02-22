module apps

import net

import time
import sync2
import sync2.atomic3
import sync

import sync.atomic2

pub struct EndpointApp {
	args              Args
mut:
	pool              &sync2.TaskPool
	listen            &net.TcpListener = voidptr(0)
	loopback_mutex    sync.Mutex
	loopback_conns    map[int]&net.TcpConn
	relay_conn        &net.TcpConn = voidptr(0)
	relay_write_queue chan Packet
	last_client_index int
	stats             &Stats

	// debugging
	last_size         int
	last_header          PacketHeader
	
}

pub fn new_endpoint(a Args) &EndpointApp {
	return &EndpointApp{
		args: a
		pool: sync2.new_pool_processor({
			maxjobs: max_jobs
		})
		loopback_mutex: sync.new_mutex()
		stats: &Stats{}
		relay_write_queue: chan Packet{cap:max_write_queue_size}
	}
}

fn (mut app EndpointApp) queue_relay_data(data []byte) {
	app.relay_write_queue <- packet_from_data(data)
	atomic2.add_u64(&app.stats.behind, 1)

}

fn (mut app EndpointApp) disconnect_loopback(id int) ? {
	app.loopback_mutex.@lock()
	defer {app.loopback_mutex.unlock()}

	if id in app.loopback_conns.keys() {
		mut c := app.loopback_conns[id]
		c.close()?
		app.loopback_conns.delete_1(id)
		// queue drop packet to be sent
		app.queue_relay_data(build_drop_packet(id))
	}
	return none
}

[inline]
fn (mut app EndpointApp) loopback(id int) ?&net.TcpConn {
	app.loopback_mutex.@lock()
	defer {
		app.loopback_mutex.unlock()
	}
	if id in app.loopback_conns {
		return app.loopback_conns[id]
	}
	return none
}

fn (mut app EndpointApp) shutdown_pool(err string, code int) {
	println('shutdown: $code $err: shutting down pool')
	app.relay_conn.close() or {
		println('shutdown: $err $errcode: shutdown conn failed')
	}
	app.pool.shutdown()
	app.relay_write_queue.close()
}

struct LoopbackFrameTaskContext {
	id     int
mut:
	buffer []byte
}

[inline]
fn (mut app EndpointApp) loopback_frame(id int, mut buffer []byte) ? {
	mut packet_header := &PacketHeader(buffer.data)
	mut c := app.loopback(id) or {
		return error('No loopback with id exists anymore')
	}
	// Read into the buffer after the space for the packet header
	read := c.read(mut buffer[header_size..]) or {
		// Nothing to read from this loopback so move on
		if errcode == net.err_timed_out_code {
			return none
		}
		println('read: [$id] $errcode $err: Disconnecting loopback')
		app.disconnect_loopback(id)?
		return error('Disconnection')
	}
	if read == 0 {
		return none
	}
	atomic2.add_u64(&app.stats.frontside_read, read)
	// Setup the packet header for this loopback
	packet_header.id = id
	packet_header.size = read
	packet_header.@type = .data

	// queue this data to be sent to endpoint
	app.queue_relay_data(buffer[..header_size+read].clone())

	return none
}

[inline]
fn (mut app EndpointApp) relay_write_frame() ? {
	for {
		packet := <-app.relay_write_queue or {
			if app.pool.has_shutdown() {
				return none
			}
		}

		packet.check()
		mut sent := 0
		for sent != packet.data.len {
			sent += app.relay_conn.write(packet.data) or {
				if errcode == net.err_timed_out_code {
					// println('relay_write_frame: blocked')
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

struct RelayFrameTaskContext {
mut:
	buffer []byte
}

[inline]
fn (mut app EndpointApp) relay_frame(mut buffer []byte) ? {
	mut packet_header := &PacketHeader(buffer.data)
	for {
		// First just read the header so we know how much to then read
		mut read := 0
		for read != header_size {
			read += app.relay_conn.read(mut buffer[read..header_size]) or {
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
			println('relay: Invalid packet type ${u32(packet_header.@type)}')
			return error('invalid packet type from relay: ${u32(packet_header.@type)}')
		}
		match packet_header.@type {
			.data {
				if size == 0 {
					println('relay: [$id]: 0-size packet')
					return none
				}

				// Read all bytes of this payload into the buffer
				read = 0
				for read < size {
					read += app.relay_conn.read(mut buffer[header_size+read..header_size + size]) or {
						if errcode == net.err_timed_out_code {
							continue
						}
						// Something tragic happened...
						return error_with_code(err, errcode)
					}
				}

				app.last_size = read
				app.last_header = packet_header

				atomic2.add_u64(&app.stats.backside_read, size + header_size)
				if id !in app.loopback_conns {
					// Create a new loopback connection
					println('connect: [$id] new')
					mut new_conn := net.dial_tcp('127.0.0.1:$app.args.app_port')?
					new_conn.set_read_timeout(net.no_timeout)
					new_conn.set_write_timeout(net.no_timeout)
					app.loopback_mutex.@lock()
					app.loopback_conns[id] = new_conn
					app.loopback_mutex.unlock()
					
					// queue new task to handle this loopback
					app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
						mut a := &EndpointApp(t.item)
						mut ctx := &LoopbackFrameTaskContext(t.context)
						// sync2.set_thread_desc(sync2.thread_id(), 'loopback_frame[$ctx.id]')
						a.loopback_frame(ctx.id, mut ctx.buffer) or {
							// Error happened so we are done with this client
							// TODO we need to free memory here
							println('loopback: $err $errcode: finished')
							return .finished
						}
						return .yield
					}, app, voidptr(&LoopbackFrameTaskContext{
						id: id
						buffer: new_data_buffer()
					}))
					
					println('connect: [$id] connected')
				}

				// Send data back to loopback
				for {
					app.loopback_conns[id].write(buffer[header_size..header_size + size]) or {
						if errcode == net.err_timed_out_code {
							// TODO dont do this it will block everyone else
							continue
						}
						println('write: [$id] $errcode $err: Disconnecting loopback')
						app.disconnect_loopback(id)?
						break
					}
					break
				}
				atomic2.add_u64(&app.stats.frontside_wrote, size + header_size)
			}
			.drop {
				println('drop: [$id]: Dropping by request')
				app.disconnect_loopback(id)?
			}
		}
		if app.pool.has_shutdown() {
			return none
		}
	}
	println('yielded')
	return none
}


pub fn (mut app EndpointApp) run() ? {
	println('Endpoint starting - listening to app on $app.args.app_port and connecting to relay on $app.args.relay_ip')
	for {
		for {
			println('Waiting for relay...')
			app.relay_conn = net.dial_tcp('$app.args.relay_ip') or {
				println('$errcode $err')
				continue
			}
			app.relay_conn.sock.set_option_int(.send_buf_size, tcp_buffer_size)?
			app.relay_conn.sock.set_option_int(.recieve_buf_size, tcp_buffer_size)?
			// app.relay_conn.set_read_timeout(net.no_timeout)
			// app.relay_conn.set_write_timeout(net.no_timeout)
			break
		}
		println('Got relay - pumping!')
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &EndpointApp(t.item)
			// sync2.set_thread_desc(sync2.thread_id(), 'relay_write_frame')
			a.relay_write_frame() or {
				a.shutdown_pool(err, errcode)
				println('relay_write_frame: $err $errcode: finished')
				return .finished
			}
			return .yield
		}, app, voidptr(0))
		// Task to listen to relay
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			mut a := &EndpointApp(t.item)
			mut ctx := &RelayFrameTaskContext(t.context)
			// sync2.set_thread_desc(sync2.thread_id(), 'relay_frame')
			// println('relay: frame')
			a.relay_frame(mut ctx.buffer) or {
				// Relay task finished so we need to reconnect anyway
				// say that we are shutting down
				a.shutdown_pool(err, errcode)
				// TODO we need to free memory here
				println('relay: $err $errcode: finished')
				return .finished
			}
			return .yield
		}, app, voidptr(&RelayFrameTaskContext{
			buffer: new_data_buffer()
		}))
		// Task for stats
		app.pool.add_task(fn (t &sync2.Task, tid int) sync2.TaskResult {
			// sync2.set_thread_desc(sync2.thread_id(), 'stats_frame')
			time.sleep(1)
			mut a := &EndpointApp(t.item)
			a.stats.print_stats(a.loopback_conns.len)
			return .yield
		}, app, voidptr(0))
		// Work and wait for shutdown
		app.pool.work()
		println('run: pool shutdown finished')
		// Cleanup any connections that might have existed
		app.relay_conn.close() or {
		}
		for id, mut c in app.loopback_conns {
			c.close() or {
			}
			app.loopback_conns.delete_1(id)
		}
	}
	println('endpoint: restarting')

	return none
}
