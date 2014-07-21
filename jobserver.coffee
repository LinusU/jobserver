{EventEmitter} = require('events')
{Transform} = require('stream')
crypto = require('crypto')

BLOB_HMAC_KEY = 'adb97d77011182f0b6884f7a6d32280a'
JOB_HMAC_KEY  = 'fb49246c50d78d460a5d666e943230fa'

STATES = [
	'waiting'   # depends on outputs of other jobs that have not finished yet
	'pending'   # ready to run, but blocked on hardware resources
	'running'   # self-explanatory
	'success'   # Ran and produced its outputs
	'fail'      # Ran and failed to produce its outputs. This status is cached. Another run with the same inputs would also fail.
	'abort'     # Ran and did not produce its output due to e.g. a network problem. Running again may succeed.
]

# A `Server` maintains the global job list and aggregates events for the UI
@Server = class Server extends EventEmitter
	constructor: (@jobStore, @blobStore) ->
		@activeJobs = {}

	counter = 0
	makeJobId: -> (counter++)

	submit: (job, doneCb) ->
		server = this
		job.id = @makeJobId()
		@activeJobs[job.id] = job

		server.emit 'submit', job

		job.on 'state', (state) ->
			server.emit 'job.state', this, state

		job.once 'settled', =>
			delete @activeJobs[job.id]
			doneCb() if doneCb

		job.submitted(this)

	jsonableState: ->
		jobs = for id, job of @activeJobs
			job.jsonableState()

		{jobs}

# A `FutureResult` is a reference to a result of a `Job` which may not yet have completed
@FutureResult = class FutureResult
	constructor: (@job, @key) ->
	get: ->
		if @job.status == 'success'
			@job.result[@key]
		else
			throw new Error("Accessing result of job with status #{@job.status}")

# `BlobStore` is the abstract base class for result file data storage.
# Subclasses persist Buffers and retrieve them by hash.
@BlobStore = class BlobStore
	newBlob: (buffer, meta) ->
		throw new Error("Abstract method")
	getBlob: (id, cb) ->
		throw new Error("Abstract method")
	hash: (buffer) ->
		crypto.createHmac('sha256', BLOB_HMAC_KEY).update(buffer).digest().toString('base64')

# An item in a BlobStore
class Blob
	constructor: (@store, @id, @meta, @cached) ->

# Abstact base class for database of job history
@JobStore = class JobStore

# A Stream transformer that captures a copy of the streamed data and passes it through
class TeeStream extends Transform
	constructor: ->
		super()
		@log = ''

	_transform: (chunk, encoding, callback) ->
		@log += chunk.toString('utf8')
		this.push(chunk)
		callback()

# Object containing the state and logic for a job. Subclasses can override the behavior
@Job = class Job extends EventEmitter
	constructor: (@executor=undefined, @pure=false, @inputs={}, @explicitDependencies=[], resultNames=[]) ->
		@state = null
		@result = {}
		for key in resultNames
			@result[key] = new FutureResult(this, key)

	jsonableState: ->
		{@id, @name, @description, @state, settled: @settled()}

	submitted: (@server) ->
		@executor ?= @server.defaultExecutor
		
		@dependencies = @explicitDependencies.slice(0)
		for i in @inputs
			if i instanceof FutureResult
				@dependencies.push(i.job)

		for dep in @dependencies
			if not dep.state?
				server.submit(dep)

			unless dep.settled()
				dep.once 'settled', =>
					@checkDeps()

		@saveState 'waiting'
		@checkDeps()

	checkDeps: ->
		unless @state is 'waiting'
			throw new Error("checkDeps in state #{@state}")

		ready = true
		for dep in @dependencies
			switch dep.state
				when 'error'
					return @saveState 'error'
				when 'abort'
					return @saveState 'abort'
				when 'success'
					# nothing
				else
					ready = false

		if ready
			if @pure
				@server.jobStore.resultByHash @hash(), (completion) =>
					if result
						@result.fromCache = completion.id or true
						{@result, @startTime, @endTime} = completion
						@saveState(completion.status)
					else
						@enqueue()
			else
				@enqueue()

	hash: ->
		unless @pure
			throw new Error("Can't hash impure job (pure jobs cannot depend on impure jobs)")

		unless @_hash
			hasher = crypto.createHmac('sha256', JOB_HMAC_KEY)
			hasher.update(@name)

			depHashes = (dep.hash() for dep in @explicitDependencies)
			depHashes.sort()
			hasher.update(hash) for hash in depHashes

			for key in Object.keys(@inputs).sort()
				hasher.update(key)
				hasher.update(":")
				value = @inputs[key]
				if value instanceof FutureResult
					value = value.get()

				if value instanceof Blob
					hasher.update(value.hash)
				else
					hasher.update(JSON.stringify(value))
				hasher.update(",")

			@_hash = hasher.digest()

		@_hash

	enqueue: ->
		@saveState 'pending'
		@executor.enqueue(this)

	settled: ->
		@state in ['success', 'fail', 'abort']

	saveState: (state) ->
		if state not in STATES
			throw new Error("Invalid status '#{state}'")
		@state = state
		@emit 'state', state

		if @settled()
			@emit 'settled'

	beforeRun: ->
		@startTime = new Date()
		@saveState 'running'
		
	afterRun: (result) ->
		@endTime = new Date()
		@fromCache = false

		if @pure
			@emit 'computed'

		if result
			@result = result
			@saveState('success')
		else
			@saveState('fail')

	name: ''
	description: ''

	# Override this
	run: (ctx, cb) ->
		ctx.write("Default exec!")
		setImmediate( -> cb(false) )

# An in-memory BlobStore
@BlobStoreMem = class BlobStoreMem extends BlobStore
	constructor: ->
		@blobs = {}

	putBlob: (buffer, meta) ->
		id = @hash(buffer)
		if not @blobs[id]
			@blobs[id] = new Blob(this, id, meta, buffer)
		@blobs[id]

	getBlob: (id, cb) ->
		v = @blobs[id]
		setImmediate ->
			cb(v)
		return

@JobStoreMem = class JobStoreMem extends JobStore
	constructor: ->

# An Executor manages the execution of a set of jobs. May also wrap access to an execution resource
@Executor = class Executor
	enqueue: (job) ->
		ctx = new this.Context(job)
		ctx.before (err) ->
			throw err if err
			job.beforeRun()
			job.run(ctx)
	
	# An Executor provides a Job a Context to access resources
	Context: class Context extends TeeStream
		constructor: (@job)->
			super()
			@queue = []
			
		before: (cb) ->
			setImmediate(cb)
		
		after: (cb) ->
			setImmediate(cb)
			
		done: (result) ->
			unless @queue.length
				@_done(result)
			
		_done: (err) ->
			if err
				@write("Failed with error: #{err.stack}")
			
			@after (err) =>
				throw err if err
				@end()
				@job.log = @log
				@job.afterRun(!err)

# An executor combinator that runs jobs one at a time in series on a specified executor
@SeriesExecutor = class SeriesExecutor extends Executor
	constructor: (@executor) ->
		super()
		@currentJob = null
		@queue = []

	enqueue: (job) =>
		@queue.push(job)
		@shift() unless @currentJob

	shift: =>
			@currentJob = @queue.shift()
			if @currentJob
				@currentJob.on 'settled', @shift
				@executor.enqueue(@currentJob)
