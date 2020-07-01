module atomic3

import sync.atomic2

fn C.atomic_compare_exchange_strong() int

pub fn atomic_compare_exchange_strong(object &u64, expected, desired u64) bool {
	res := C.atomic_compare_exchange_strong(object, &expected, desired)
	return res == 1
}

fn C.atomic_exchange_explicit() u64

pub fn atomic_exchange(target &u64, desired u64) u64 {
	x := C.atomic_exchange_explicit(target, desired)
	return x
}

fn zzzzz_dont_look_at_me_im_not_important() {
	// Stop the compiler complaining that modules arent used
	x := u64(0)
	atomic2.add_u64(&x, 0)
}