module sync2

import sync2.atomic3

// I guess you could call this a futex?
pub struct Mutex {
mut:
	// atomic
	state u64
}

pub fn new_mutex() &Mutex {
	sm := &Mutex{}
	return sm
}

pub fn (mut m Mutex) lock() {
	for !atomic3.atomic_compare_exchange_strong(&m.state, 0, 1) {
		thread_yield()
	}
}

pub fn (mut m Mutex) unlock() {
	if !atomic3.atomic_compare_exchange_strong(&m.state, 1, 0) {
		panic('Mutex in undefined state')
	}
}