module apps

import net
import sync2.atomic3

pub struct Args {
pub:
	relay_ip   string
	relay_port int
	app_port   int
	count      int
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
	id    int
	// Size of the following payload (should be 1..data_size)
	size  int
}

struct Packet {
pub mut:
	data []byte
	len int
}

pub fn packet_from_data(data []byte) Packet {
	return Packet {
		data: data
		len: data.len
	}
}

pub fn (p Packet) header() &PacketHeader {
	return &PacketHeader(p.data.data)
}

pub fn (p Packet) free() {
	unsafe {
		p.data.free()
	}
}

pub fn (p Packet) check() {
	if p.header().size + header_size != p.len {
		panic('invalid packet ${p.header()}')
	}
}

const (
	data_size   = 8192
	header_size = int(sizeof(PacketHeader))
	max_write_queue_size = 200
	max_jobs = 0
	tcp_buffer_size = 100 * 1024 // * 1024
	header_magic = u32(1396786757)
)

fn new_data_buffer() []byte {
	return []byte{len: data_size, cap: data_size + header_size, init: 0}
}

fn send_drop_packet(mut conn &net.TcpConn, id int) ? {
	// Tell the endpoint this client is gone
	// so that it doesnt keep sending us data we will
	// just throw away
	p := PacketHeader{
		@type: .drop
		id: id
		size: 0
	}
	// Fake a buffer out of it
	b := array{
		data: &p
		len: header_size
	}
	conn.write(b)?
	return none
}

fn build_drop_packet(id int) []byte {
	// Tell the endpoint this client is gone
	// so that it doesnt keep sending us data we will
	// just throw away

	b := []byte{ len: header_size }

	mut p := &PacketHeader(b.data)
	p.@type = .drop
	p.id = id
	p.size = 0

	return b
}

struct Stats {
	frontside_read  u64
	frontside_wrote u64
	backside_read   u64
	backside_wrote  u64
	behind          u64
}

fn (mut stats Stats) print_stats(conns int) {
	frontside_read := u64(atomic3.exchange(&stats.frontside_read, 0)) / 1024
	frontside_wrote := u64(atomic3.exchange(&stats.frontside_wrote, 0)) / 1024
	backside_read := u64(atomic3.exchange(&stats.backside_read, 0)) / 1024
	backside_wrote := u64(atomic3.exchange(&stats.backside_wrote, 0)) / 1024
	println('stats: connections: $conns')
	println('stats:   behind by: $stats.behind')
	println('stats:   frontside: ${frontside_read}Kbit/${frontside_wrote}Kbit')
	println('stats:    backside: ${backside_read}Kbit/${backside_wrote}Kbit')
	println('stats:        neck: ${backside_read}Kbit/${frontside_wrote}Kbit ${frontside_read}Kbit/${backside_wrote}Kbit')
}
