assert = require 'assert'
jobserver = require '../index'

describe 'blobStoreMem', ->
	it 'stores and retrieves blobs', (next) ->
		s = new jobserver.BlobStoreMem()
		data = new Buffer('asdfghjkl')
		b1 = s.putBlob(data)
		s.getBlob b1.id, (resultData) ->
			assert.equal(data, resultData)
			next()

	it 'hashes identical blobs to the same id', ->
		s = new jobserver.BlobStoreMem()
		data = new Buffer('asdfghjkl')
		b1 = s.putBlob(data)
		b2 = s.putBlob(data)
		assert.equal(b1.id, b2.id)
		assert.equal(b1.data, b2.data)

# Takes a list of names and returns an object with methods with those names, which must be called in order
orderingSpy = (events) ->
	r = {}
	counter = 0

	events.forEach (name) ->
		r[name] = ->
			if events[counter] == name
				counter++
			else
				throw new Error("`#{name}` called in the wrong order (expected `#{events[counter]}` next)")

	return r

describe 'orderingSpy', ->
	it 'passes', ->
		o = orderingSpy(['a', 'b', 'c', 'c', 'd'])
		o.a()
		o.b()
		o.c()
		o.c()
		o.d()

	it 'fails', ->
		o = orderingSpy(['a', 'b', 'c', 'd'])
		assert.throws ->
			o.a()
			o.b()
			o.d()
			o.c()

class TestJob extends jobserver.Job
	constructor: (@run) ->
		super()

describe 'Job', ->
	jobstore = blobstore = server = null

	beforeEach ->
		jobstore = new jobserver.JobStoreMem()
		blobstore = new jobserver.BlobStoreMem()
		server = new jobserver.Server(jobstore, blobstore)
		server.defaultExecutor = new jobserver.Executor()

	it 'Runs and emits states and collects a log', (cb) ->
		ordered = orderingSpy(['waiting', 'pending', 'running', 'exec', 'success', 'settled'])
		job = new TestJob (ctx, cb) ->
			ordered.exec()
			ctx.write("test1\n")
			ctx.write("test2\n")

		job.on 'state', (s) ->
			ordered[s]()

		job.on 'settled', ->
			ordered.settled()
			assert.equal(job.log, 'test1\ntest2\n')
			cb()

		server.submit(job)

	it 'Runs dependencies in order', (done) ->
		ordered = orderingSpy(['prestart', 'depstart', 'depstart' , 'parentstart'])

		job0 = new TestJob (ctx) ->
			ordered.prestart()
		job1 = new TestJob (ctx) ->
			ordered.depstart()
		job2 = new TestJob (ctx) ->
			ordered.depstart()
		job3 = new TestJob (ctx) ->
			ordered.parentstart()

		job1.explicitDependencies.push(job0)
		job2.explicitDependencies.push(job0)
		job3.explicitDependencies.push(job1, job2)

		server.submit job3, ->
			done()

	it 'Generates implicit dependencies based on input'
	it 'Rejects dependency cycles'
	it 'Hashes consistently'
	it 'Avoids recomputing calculated jobs'

describe 'SeriesExecutor', ->
		e = null
		beforeEach ->
			e = new jobserver.SeriesExecutor(new jobserver.Executor())

		it 'Runs jobs in order', (cb) ->
			spy = new orderingSpy(['j1_start', 'j1', 'j2', 'j3_start', 'j3'])
			j1 = new TestJob (ctx) ->
				spy.j1_start()
				ctx.then (cb) ->
					spy.j1()
					setTimeout(cb, 20)

			j2 = new TestJob (ctx) ->
				spy.j2()

			j3 = new TestJob (ctx) ->
				spy.j3_start()
				ctx.then (cb) ->
					spy.j3()
					cb(new Error("test failure (should fail)"))

			j1.enqueue(e)
			j2.enqueue(e)
			j3.enqueue(e)
			
			j3.on 'settled', -> cb()
			
describe 'LocalExecutor', ->
		server = null
		e = null
		blobstore = null
		beforeEach ->
			jobstore = new jobserver.JobStoreMem()
			blobstore = new jobserver.BlobStoreMem()
			server = new jobserver.Server(jobstore, blobstore)
			e = new jobserver.LocalExecutor()
			
		it 'Runs subtasks with a queue', (cb) ->
			j = new TestJob (ctx) ->
				spy = new orderingSpy(['a', 'b', 'c'])
				assert(ctx.dir)
				ctx.then (n) ->
					spy.a()
					n()
				ctx.then (n) ->
					spy.b()
					setTimeout(n, 10)
					ctx.then (n) ->
						spy.c()
						n()
			j.enqueue(e)
			j.on 'settled', -> cb()
			
		it 'Runs commands', (cb) ->
			j = new TestJob (ctx) ->
				ctx.run('touch test.txt')
			j.enqueue(e)
			j.on 'settled', ->
				assert.equal(j.state, 'success')
				cb()
			
		it 'Fails if commands fail', (cb) ->
			j = new TestJob (ctx) ->
				ctx.run('false')
			j.enqueue(e)
			j.on 'settled', ->
				assert.equal(j.state, 'fail')
				cb()
				
		it 'Saves files', (cb) ->
			j = new TestJob (ctx) ->
				ctx.run('echo hello > test.txt')
				ctx.get('test', 'test.txt')
			j.executor = e
			server.submit j, ->
				assert.equal(j.state, 'success')
				j.result.test.getBuffer (data) ->
					assert.equal(data.toString('utf8'), 'hello\n')
					cb()
				
		it 'Loads files', (cb) ->
			b = blobstore.putBlob(new Buffer("Hello\n"))
			j = new TestJob (ctx) ->
				ctx.put(@inputs.test, 'test.txt')
				ctx.run 'echo Hello > test2.txt'
				ctx.run 'diff -u test.txt test2.txt'
			j.executor = e
			j.inputs.test = b
			server.submit j, ->
				assert.equal(j.state, 'success')
				cb()
