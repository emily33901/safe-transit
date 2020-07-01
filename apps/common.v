module apps

import emily33901.net

pub struct Args {
pub:
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
	data_size = 4096
	header_size = int(sizeof(PacketHeader))
)

fn new_data_buffer() []byte {
	return []byte{ len: data_size, cap: data_size + header_size, init: 0 }
}

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