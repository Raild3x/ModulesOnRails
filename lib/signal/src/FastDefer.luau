--!native
--!optimize 2
--!strict

-- Initial capacity hint for the free-thread pool, not a hard cap: `table.insert` still
-- grows the array past this if more threads are deferred concurrently than this.
const INITIAL_THREAD_POOL_CAPACITY = 256
const FreeThreads: { thread } = table.create(INITIAL_THREAD_POOL_CAPACITY) :: any

-- A thread only rejoins the pool once `callback` returns *synchronously*. If a deferred
-- callback yields instead (e.g. `task.wait`), this thread is silently dropped from the
-- pool for good — the coroutine itself stays alive (owned by whatever suspended it), but
-- `FastDefer` permanently loses that pool slot. This is the actual mechanism behind
-- `Signal:FireDeferredUnsafe` being documented as "unsafe".
const function RunFunction<Arguments...>(callback: (Arguments...) -> (), thread: thread, ...: Arguments...)
	callback(...)
	table.insert(FreeThreads, thread)
end

const function Yield()
	while true do
		RunFunction(coroutine.yield())
	end
end

const function FastDefer<Arguments...>(callback: (Arguments...) -> (), ...: Arguments...)
	local thread: thread
	const freeAmount = #FreeThreads

	if freeAmount > 0 then
		thread = FreeThreads[freeAmount]
		FreeThreads[freeAmount] = nil
	else
		thread = coroutine.create(Yield)
		coroutine.resume(thread)
	end

	return task.defer(thread, callback, thread, ...)
end

return FastDefer
