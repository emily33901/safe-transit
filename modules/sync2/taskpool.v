module sync2

import runtime
import time
import sync
import sync2.atomic3

const (
	task_limit = 2000
)

enum TaskResult {
	yield
	finished
}

pub type TaskFn = fn (t &Task, thread_id int) TaskResult

pub struct Task {
	cb      TaskFn
pub mut:
	item    voidptr
	context voidptr
}

pub struct TaskPool {
pub mut:
	njobs          int
mut:
	tasks          chan Task
	waitgroup      &sync.WaitGroup
	shared_context voidptr

	// atomic
	shutdown u64
	active u64
}

pub struct TaskPoolConfig {
	maxjobs int
}

// new_pool_processor returns a new TaskPool instance.
pub fn new_pool_processor(context TaskPoolConfig) &TaskPool {
	pool := &TaskPool{
		tasks: chan Task{cap: task_limit}
		shared_context: voidptr(0)
		njobs: context.maxjobs
		waitgroup: sync.new_waitgroup()
		shutdown: 0
	}
	return pool
}

// set_max_jobs gives you the ability to override the number
// of jobs *after* the TaskPool had been created already.
pub fn (mut pool TaskPool) set_max_jobs(njobs int) {
	pool.njobs = njobs
}

pub fn (mut pool TaskPool) add_task(cb TaskFn, item voidptr, context voidptr) {
	pool.add_task_internal(Task{
		cb: cb
		item: item
		context: context
	})
}

fn (mut pool TaskPool) add_task_internal(t Task) {
	// add to task channel
	pool.tasks <- t
}

pub fn (mut pool TaskPool) work() {
	mut njobs := runtime.nr_jobs()
	if pool.njobs > 0 {
		njobs = pool.njobs
	}
	pool.njobs = njobs
	pool.waitgroup.add(njobs)
	pool.active = u64(njobs)

	// make sure to reset the pool before running the tasks
	pool.shutdown = 0

	for i := 0; i < njobs; i++ {
		if njobs > 1 {
			go process_in_thread(mut pool, i)
		} else {
			// do not run concurrently, just use the same thread:
			process_in_thread(mut pool, i)
		}
	}
	pool.waitgroup.wait()

	pool.tasks = chan Task{cap:task_limit}
}

pub fn (mut pool TaskPool) shutdown() {
	println('pool: shutting down')
	pool.tasks.close()
	atomic3.store(&pool.shutdown, 1)
}

pub fn (pool &TaskPool) has_shutdown() bool {
	return pool.shutdown == 1
}

fn process_in_thread(mut pool TaskPool, thread_id int) {
	for {
		if !select {
			task := <-pool.tasks {
				f := task.cb
				res := f(&task, thread_id)
				if res == .yield {
					pool.add_task_internal(task)
				} else {
					// did not yield so do not add back
				}
			}
			> 10 * time.second {
				// println('pool: [$thread_id] starved')
			}
		} {
			atomic3.fetch_add(&pool.active, u64(-1))
			// pool is shutting down
			println('pool: [$thread_id] finished ($pool.active remaining...)')
			break
		}

	}
	pool.waitgroup.done()
}

fn (pool &TaskPool) get_shared_context() voidptr {
	return pool.shared_context
}

fn (mut pool TaskPool) set_shared_context(c voidptr) {
	pool.shared_context = c
}
