module sync2

import runtime
import sync
import time

enum TaskResult {
	yield finished
}

pub struct Task {
	cb voidptr
pub:
	item voidptr
	context voidptr
}

pub struct YieldingPoolProcessor {
pub mut:
	njobs           int
mut:
	task_mutex      &Mutex
	// writing to these should be locked by task_mutex.
	tasks           []Task
	// Atomic
	shutdown        u64
	waitgroup       &sync.WaitGroup
	shared_context  voidptr
	idle_time int
}

pub type ThreadCB fn(p &YieldingPoolProcessor, t &Task, thread_id int) TaskResult

pub struct YieldingPoolProcessorConfig {
	maxjobs  int
}

// new_pool_processor returns a new YieldingPoolProcessor instance.
pub fn new_pool_processor(context YieldingPoolProcessorConfig) &YieldingPoolProcessor {
	pool := &YieldingPoolProcessor {
		tasks: []
		shared_context: voidptr(0)
		njobs: context.maxjobs
		task_mutex: new_mutex()
		waitgroup: sync.new_waitgroup()
		shutdown: 0
		idle_time: 100
	}
	return pool
}

// set_max_jobs gives you the ability to override the number
// of jobs *after* the YieldingPoolProcessor had been created already.
pub fn (mut pool YieldingPoolProcessor) set_max_jobs(njobs int) {
	pool.njobs = njobs
}

pub fn (mut pool YieldingPoolProcessor) add_task(cb ThreadCB, item voidptr, context voidptr) {
	pool.add_task_internal(Task{
		cb: cb
		item: item
		context: context
	})
}

fn (mut pool YieldingPoolProcessor) add_task_internal(t Task) {
	pool.task_mutex.lock()
	defer { pool.task_mutex.unlock() }
	pool.tasks << t
}

pub fn (mut pool YieldingPoolProcessor) remove_task(idx int) {
	pool.task_mutex.lock()
	defer { pool.task_mutex.unlock() }
	// remove task
	pool.tasks.delete(idx)
}

pub fn (mut pool YieldingPoolProcessor) work() {
	mut njobs := runtime.nr_jobs()
	if pool.njobs > 0 {
		njobs = pool.njobs
	}
	pool.njobs = njobs
	pool.waitgroup.add(njobs)
	for i := 0; i < njobs; i++ {
		if njobs > 1 {
			go process_in_thread(mut pool,i)
		} else {
			// do not run concurrently, just use the same thread:
			process_in_thread(mut pool,i)
		}
	}
	pool.waitgroup.wait()

	// Shutdown finished so we are going to be ready to start new tasks again
	pool.tasks.free()
	pool.tasks = []Task{}
	pool.shutdown = 0
}

fn (mut pool YieldingPoolProcessor) get_task() ?Task {
	pool.task_mutex.lock()
	defer { pool.task_mutex.unlock() }

	if pool.tasks.len == 0 {
		return none
	}
	task := pool.tasks[0]
	pool.tasks.delete(0)
	
	return task
}


fn (mut pool YieldingPoolProcessor) has_shutdown() bool {
	expected := u64(1)
	desired := u64(1)
	res := C.atomic_compare_exchange_strong(&pool.shutdown, &expected, desired)
	return res == 1
}

pub fn (mut pool YieldingPoolProcessor) shutdown() {
	expected := u64(0)
	desired := u64(1)
	C.atomic_compare_exchange_strong(&pool.shutdown, &expected, desired)
}

pub fn (mut pool YieldingPoolProcessor) set_idle_time(i int) {
	pool.idle_time = i
}

// process_in_thread does the actual work of worker thread.
// It is a workaround for the current inability to pass a
// method in a callback.
fn process_in_thread(mut pool YieldingPoolProcessor, thread_id int) {
	for {
		if pool.has_shutdown() { break }
		if task := pool.get_task() {
			cb := ThreadCB(task.cb)
			res := cb(pool, &task, thread_id)
			if res == .yield {
				// Task yielded so put it back in
				pool.add_task_internal(task)
			} else {
				// println('task finished')
			}
		} else {
			time.sleep_ms(pool.idle_time)
		}
		thread_yield()
	}
	pool.waitgroup.done()
}

fn (pool &YieldingPoolProcessor) get_shared_context() voidptr {
	return pool.shared_context
}

fn (mut pool YieldingPoolProcessor) set_shared_context(c voidptr) {
	pool.shared_context = c
}