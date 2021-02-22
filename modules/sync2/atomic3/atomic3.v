module atomic3

import sync.atomic2

fn C.atomic_compare_exchange_strong() int

pub fn compare_exchange_strong(object &u64, expected u64, desired u64) bool {
	res := C.atomic_compare_exchange_strong(object, &expected, desired)
	return res == 1
}

fn C.atomic_compare_exchange_weak() int

pub fn compare_exchange_weak(object &u64, expected u64, desired u64) bool {
	res := C.atomic_compare_exchange_weak(object, &expected, desired)
	return res == 1
}

pub fn compare_exchange_weak_ref(object, expected &u64, desired u64) bool {
	res := C.atomic_compare_exchange_weak(object, expected, desired)
	return res == 1
}

fn C.atomic_load() u64

pub fn load(object &u64) u64 {
	return C.atomic_load(object)
}

fn C.atomic_store() u64

pub fn store(object &u64, value u64) {
	C.atomic_store(object, value)
}

fn C.atomic_exchange() u64

pub fn exchange(target &u64, desired u64) u64 {
	x := C.atomic_exchange(target, desired)
	return x
}

fn C.atomic_fetch_add() u64

pub fn fetch_add(target &u64, delta u64) u64 {
	return C.atomic_fetch_add(target, delta)
}

fn zzzzz_dont_look_at_me_im_not_important() {
	// Stop the compiler complaining that modules arent used
	x := u64(0)
	atomic2.add_u64(&x, 0)
}
