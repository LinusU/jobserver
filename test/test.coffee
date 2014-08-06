assert = require 'assert'
jobserver = require '../index'

class TestJob extends jobserver.Job
  constructor: (@run) ->
    super()

class OrderingJob extends jobserver.Job
  counter = 1
  run: (ctx) ->
    this.startTick = counter++
    ctx.then (c) =>
      setTimeout (=>
        this.endTick = counter++
        c()
      ), 1

  assertRanAfter: (job) ->
    assert job.startTick and job.endTick, "other job did not run"
    assert @startTick and @endTick, "this job did not run"
    assert job.endTick < @startTick

describe 'Job', ->
  jobstore = blobstore = server = null

  before (done) ->
    server = new jobserver.Server()
    server.defaultExecutor = new jobserver.Executor()
    server.init done

  describe 'Running a job', (cb) ->
    job = null
    order = []

    before (done) ->
      job = new TestJob (ctx) ->
        order.push('exec')
        ctx.write("test1\n")
        ctx.write("test2\n")

      job.on 'state', (s) ->
        order.push(s)

      job.on 'settled', done
      server.submit(job)

    it 'emits states', ->
      assert.deepEqual order, ['waiting', 'pending', 'running', 'exec', 'success']

    it 'collects a log', ->
      assert.equal(job.log, 'test1\ntest2\n')

  describe 'Running dependent jobs', (done) ->
    jobs = []
    before (done) ->
      makeJob = (deps...) ->
        j = new OrderingJob()
        j.explicitDependencies.push(deps...)
        j

      #          1
      #  5 - 3 <   > 0
      #   \      2
      #    4

      jobs[0] = makeJob()
      jobs[1] = makeJob(jobs[0])
      jobs[2] = makeJob(jobs[0])
      jobs[3] = makeJob(jobs[1], jobs[2])
      jobs[4] = makeJob()
      jobs[5] = makeJob(jobs[4], jobs[3])

      server.submit jobs[5], ->
        done()

    it 'runs dependencies before dependants', ->
      jobs[1].assertRanAfter(jobs[0])
      jobs[2].assertRanAfter(jobs[0])
      jobs[3].assertRanAfter(jobs[1])
      jobs[3].assertRanAfter(jobs[2])
      jobs[5].assertRanAfter(jobs[3])
      jobs[5].assertRanAfter(jobs[4])

    checkRelated = (id, relatedIds, cb) ->
      server.relatedJobs jobs[id].id, (l) ->
        assert.deepEqual (i.id for i in l).sort(), (jobs[i].id for i in relatedIds).sort()
        cb()

    it 'persists children of root jobs to the database', (done) ->
      checkRelated 5, [0, 1, 2, 3, 4, 5], done

    it 'persists parents of child jobs to the database', (done) ->
      checkRelated 0, [0, 1, 2, 3, 5], done

    it 'persists children and parents of middle jobs to the database', (done) ->
      checkRelated 2, [0, 2, 3, 5], done

  it 'Fails if dependencies fail', (done) ->
    j1 = new TestJob (ctx) ->
      ctx.then (cb) -> cb("testErr")
    j3 = new TestJob (ctx) ->
      ctx.then (cb) -> setTimeout(cb, 1)
    j2 = new TestJob (ctx) ->
    j2.explicitDependencies.push(j1)
    j2.explicitDependencies.push(j3)
    server.submit j2, ->
      assert.equal j1.state, 'fail'
      assert.equal j2.state, 'fail'
      done()

  it 'Can run a job as a step of another', (done) ->
    order = []
    j1 = new TestJob (ctx) ->
      ctx.then (cb) ->
        order.push 'before'
        cb()
      ctx.runJob new TestJob (ctx) ->
        order.push 'sub'
      ctx.then (cb) ->
        order.push 'after'
        cb()
    server.submit j1, ->
      assert.equal j1.state, 'success'
      assert.deepEqual order, ['before', 'sub', 'after']

      server.relatedJobs j1.id, (l) ->
        assert.equal l.length, 2
        done()

  it 'Generates implicit dependencies based on input'
  it 'Rejects dependency cycles'
  it 'Hashes consistently'
  it 'Avoids recomputing calculated jobs'

describe 'SeriesExecutor', ->
    e = null
    beforeEach ->
      e = new jobserver.SeriesExecutor(new jobserver.Executor())

    it 'Runs jobs in order', (done) ->
      jobs = (new OrderingJob() for i in [0...3])
      j.enqueue(e) for j in jobs
      jobs[jobs.length-1].on 'settled', ->
        for i in [1...3]
          jobs[i].assertRanAfter(jobs[i-1])
        done()

describe 'LocalExecutor', ->
    server = null
    e = null
    blobstore = null
    beforeEach (done) ->
      server = new jobserver.Server()
      e = new jobserver.LocalExecutor()
      server.init done

    it 'Runs subtasks with a queue', (cb) ->
      order = []
      j = new TestJob (ctx) ->
        assert(ctx.dir)
        ctx.then (n) ->
          order.push 'a'
          n()
        ctx.then (n) ->
          order.push 'b'
          setTimeout(n, 10)
        ctx.then (n) ->
          order.push 'c'
          n()
      j.enqueue(e)
      j.on 'settled', ->
        assert.deepEqual order, ['a', 'b', 'c']
        cb()

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
      b = server.blobStore.putBlob(new Buffer("Hello\n"))
      j = new TestJob (ctx) ->
        ctx.put(@inputs.test, 'test.txt')
        ctx.run 'echo Hello > test2.txt'
        ctx.run 'diff -u test.txt test2.txt'
      j.executor = e
      j.inputs.test = b
      server.submit j, ->
        assert.equal(j.state, 'success')
        cb()
