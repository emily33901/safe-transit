module sync2

import time

pub fn thread_yield() {
	time.sleep_ms(0)
}

pub fn thread_id() u64 {
	$if windows {
		return u64(C.GetCurrentThreadId())
	} $else {
		return 0
	}
}

pub fn set_thread_desc(id u64, desc string) {
	$if windows {
		wide := desc.to_wide()
		C.SetThreadDescription(u32(id), wide)

		free(wide)
	}
	desc.free()
}

pub fn thread_hint_pause() {
	$if windows {
		C._mm_pause()
	}
}
