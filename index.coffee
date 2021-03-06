{EventEmitter} = require('events')
{Transform} = require('stream')
crypto = require('crypto')

util = require('util')
temp = require('temp')
rimraf = require('rimraf')
child_process = require('child_process')
path = require 'path'
fs = require 'fs'
domain = require 'domain'
async = require 'async'

hashDigest = (hash) -> hash.toString('base64').replace(/\=/g, '').replace(/\//g, '-')

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
    unless @blobStore
      @blobStore = new BlobStoreMem()
    unless @jobStore
      JobStoreSQLite = require('./jobstore_sqlite')
      @jobStore = new JobStoreSQLite(':memory:')
    @defaultResource = new Resource()

    @jobStore.blobStore = @blobStore

    @activeJobs = {}

  init: (cb) ->
    @jobStore.init(cb)

  submit: (job, doneCb) ->
    if job.settled()
      return setImmediate(doneCb)

    @transaction (t) ->
      t.submit(job, t.commit)

    job.once 'settled', doneCb if doneCb

  listenToJob: (job) ->
    @activeJobs[job.id] = job
    server = this

    job.on 'state', (state) ->
      server.emit 'job.state', this, state

    job.on 'dependencyAdded', (dep) ->
      server.emit 'job.dependencyAdded', this, dep

    job.once 'settled', =>
      delete @activeJobs[job.id]

    @emit 'submitted', job

  job: (id, cb) ->
    id = parseInt(id, 10)
    if job = @activeJobs[id]
      setImmediate -> cb(job)
    else
      @jobStore.getJob(id, cb)

  pipeLogStream: (job, dest) ->
    if job instanceof Job
      pipe = ->
        dest.write(job.ctx.log)
        job.ctx.pipe(dest)
        dest.on 'close', -> job.ctx.unpipe(dest)
      if job.ctx
        pipe()
      else
        job.on 'started', pipe
        dest.on 'close', -> job.removeListener 'started', pipe
    else
      return dest.end('') unless job.logBlob
      @blobStore.getBlob job.logBlob, (blob) ->
        dest.end(blob or '')


  relatedJobs: (id, cb) ->
    id = parseInt(id, 10)
    @jobStore.getRelatedJobs(id, cb)

  transaction: (cb) ->
    @jobStore.transaction (t) =>
      cb(new Transaction(this, t))

  toJSON: ->
    {}

class Transaction
  constructor: (@server, @jobStore) ->

  submit: (job, cb) ->
    if job.submitTime
      return job.withId(cb)

    job.server = @server
    job.state = 'waiting'
    job.submitTime = +new Date()
    job.resource ?= @server.defaultResource

    @jobStore.addJob job, =>
      @server.listenToJob(job)
      deps = job.processInputDependencies()

      submitDep = (dep, cb) =>
        @submit dep, =>
          @addDependency(job, dep, cb)

      async.each deps, submitDep, =>
        job.stateChanged('waiting')
        if job.depsFailed()
          return this.abortJob(job, cb)
        if job.depsReady()
          return this.enqueueJob(job, cb)
        else
          # If we're waiting for other jobs, let them finish, and continue
          # in a new transaction
          for dep in deps when not dep.settled()
            dep.once 'settled', (state) =>
              return if job.state != 'waiting'
              if job.depsFailed()
                @server.transaction (t) ->
                  t.abortJob(job, t.commit)
              else if job.depsReady()
                @server.transaction (t) ->
                  t.enqueueJob(job, t.commit)
          cb()

  enqueueJob: (job, cb) ->
    @jobStore.addInputs job, =>
      job.checkCache (cached) =>
        if cached
          @saveJob(job, cached.state, cb)
        else
          @saveJob job, 'pending', ->
            setImmediate -> job.enqueue()
            cb()

  addDependency: (job, dep, cb) ->
    @jobStore.addDependency job, dep, ->
      setImmediate -> job.emit 'dependencyAdded', dep
      cb()

  abortJob: (job, cb) ->
    @saveJob(job, 'abort', cb)

  saveResult: (job, success, cb) ->
    @jobStore.addResults job, =>
      @saveJob job, (if success then 'success' else 'fail'), cb

  saveJob: (job, state, cb) ->
    if state
      if state not in STATES
        throw new Error("Invalid status '#{state}'")
      job.state = state
    @jobStore.updateJob job, ->
      setImmediate -> job.stateChanged(state)
      cb()

  commit: (cb) =>
    cb ?= (->)
    @jobStore.commit(cb)


# A `FutureResult` is a reference to a result of a `Job` which may not yet have completed
@FutureResult = class FutureResult
  constructor: (@job, @key) ->
  get: ->
    if @job.results[@key] is this
      return null
    @job.results[@key]

  getBuffer: (cb) -> @get().getBuffer(cb)
  getId: -> @get().id

  toJSON: ->
    if @job.state == 'success'
      r = @get()
      if r.toJSON then r.toJSON() else r
    else
      {pending: true, jobId: @job.id}

# `BlobStore` is the abstract base class for result file data storage.
# Subclasses persist Buffers and retrieve them by hash.
@BlobStore = class BlobStore
  newBlob: (buffer, meta) ->
    throw new Error("Abstract method")
  getBlob: (id, cb) ->
    throw new Error("Abstract method")
  hash: (buffer) ->
    hashDigest(crypto.createHash('sha256').update(buffer).digest())

# An item in a BlobStore
@Blob = class Blob
  constructor: (@store, @id, @meta) ->

  getBuffer: (cb) -> @store.getBlob(@id, cb)
  getId: -> @id

  toJSON: -> {blob:true, @id}

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

@JobInfo = class JobInfo extends EventEmitter
  toJSON: ->
    {@id, @name, @description, @state, settled: @settled(),
    @submitTime, @startTime, @endTime, @pure, @hash, @inputs, @results}

  settled: ->
    @state in ['success', 'fail', 'abort']

# Object containing the state and logic for a job. Subclasses can override the behavior
@Job = class Job extends JobInfo
  resultNames: []
  pure: false

  constructor: (@resource, @inputs={}) ->
    @explicitDependencies = []
    @state = null
    @results = {}

    for key in @resultNames
      @results[key] = new FutureResult(this, key)

    @config()

  config: ->

  processInputDependencies: ->
    @dependencies = @explicitDependencies.slice(0)
    for k, v of @inputs
      if v instanceof FutureResult
        @dependencies.push(v.job)

    @dependencies

  depsReady: ->
    for dep in @dependencies
      if dep.state != 'success' then return false
    true

  depsFailed: ->
    for dep in @dependencies
      if dep.state in ['fail', 'abort'] then return true
    return false

  checkCache: (cb) ->
    if @pure
      @server.jobStore.resultByHash @hash(), (completion) =>
        if completion
          @fromCache = completion.id
          {@results, @startTime, @endTime} = completion
        cb(completion)
    else
      cb()

  withId: (cb) ->
    job = this
    if @id?
      setImmediate -> cb(job)
    else
      @once 'state', -> cb(job)

  hash: ->
    unless @pure
      throw new Error("Can't hash impure job (pure jobs cannot depend on impure jobs)")

    unless @_hash
      hasher = crypto.createHash('sha256')
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

      @_hash = hashDigest(hasher.digest())

    @_hash

  enqueue: (resource) ->
    @resource ?= resource
    @ctx = new Context(this)
    @resource.enqueue(this)
    @emit 'started'

  stateChanged: (state) ->
    @emit 'state', state
    if @settled()
      @emit 'settled'

  beforeRun: () ->
    @startTime = +new Date()

  afterRun: (cb) ->
    @endTime = +new Date()
    @fromCache = false
    @logBlob = @server.blobStore.putBlob(@ctx.log, {from: 'log', jobId: @id}, cb)

  name: ''
  description: ''

  # Override this
  run: (ctx) ->

# An in-memory BlobStore
@BlobStoreMem = class BlobStoreMem extends BlobStore
  constructor: ->
    @blobs = {}

  putBlob: (buffer, meta, cb) ->
    id = @hash(buffer)
    if not @blobs[id]
      @blobs[id] = buffer
    setImmediate(cb)
    new Blob(this, id, meta)

  getBlob: (id, cb) ->
    v = @blobs[id]
    setImmediate ->
      cb(v)
    return

# An Resource provides a Job a Context to access resources
Context: class Context extends TeeStream
  constructor: (@job)->
    super()
    @_completed = false
    @queue = []
    # Note: this needs to be piped somewhere by default so the Transform doesn't accumulate data.
    # If not stdout, then a null sink, or some other way of fixing this.
    @pipe(process.stdout)

  do: (o, cb) =>
    if not o
      cb(null)
    else if Array.isArray(o)
      async.eachSeries o, @do, cb
    else if typeof o == 'function'
      if o.length < 2
        @do o.call(@job, this), cb
      else
        o.call(@job, this, cb)
    else
      cb(new Error("Invalid value used as action: " + o))

  _done: (err) =>
    if err
      @write("Failed with error: #{err.stack ? err}\n")

    if @_completed
      console.trace("Job #{@job.constructor.name} completed multiple times")
      return
    @_completed = true

    @domain.exit()
    @domain.dispose()

    @end()
    @job.log = @log

  runJob: (child) ->
    (ctx, cb) ->
      parent = ctx.job
      parent.server.transaction (t) ->
        t.submit child, ->
          t.addDependency parent, child, t.commit

        child.once 'settled', ->
          if child.state == 'success'
            cb()
          else
            cb("Child job #{child.id} failed")

  mixin: (obj) ->
    for k, v of obj
      this[k] = v

# An Resource manages the execution of a set of jobs and provides them access to system resources
@Resource = class Resource
  enqueue: (job) ->
    job.server.transaction (t) ->
      t.saveJob job, 'running', ->
        t.commit ->
          job.beforeRun()
          job.ctx.domain = domain.create()

          next = (success) ->
            job.afterRun ->
              job.server.transaction (t) ->
                t.saveResult(job, success, t.commit)

          job.ctx.domain.on 'error', (err) ->
            job.ctx._done(err)
            next(false)

          job.ctx.domain.run ->
            job.ctx.do job.run, (err) ->
              job.ctx._done(err)
              next(!err)

# A resource combinator that runs jobs one at a time in series on a specified resource
@SeriesResource = class SeriesResource extends Resource
  constructor: (@resource) ->
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
        @resource.enqueue(@currentJob)

@LocalResource = class LocalResource extends Resource
  enqueue: (job) ->
    ctx = job.ctx
    temp.mkdir "jobserver-#{job.name}", (err, dir) =>
      ctx.mixin @ctxMixin
      ctx.dir = dir
      ctx._cwd = dir
      ctx._env ?= {}
      ctx.envImmediate(process.env)
      ctx.write("Working directory: #{dir}\n")

      ctx.on 'end', =>
        rimraf dir, ->

      Resource::enqueue.call(this, job)

  ctxMixin:
    envImmediate: (e) ->
      for k, v of e
        @_env[k] = v
      null

    env: (e) ->
      (ctx) ->
        ctx.envImmediate(e)

    cd: (p) ->
      (ctx) ->
        ctx._cwd = path.resolve(ctx._cwd, p)
        null

    run: (command, args) ->
      (ctx, cb) =>
        unless util.isArray(args)
          args = ['-c', command]
          command = 'sh'

        @write("$ #{command + if args then ' ' + args.join(' ') else ''}\n")
        p = child_process.spawn command, args, {cwd: @_cwd, env: @_env}
        p.stdout.pipe(this, {end: false})
        p.stderr.pipe(this, {end: false})
        p.on 'close', (code) =>
          cb(if code != 0 then "Exited with #{code}")

    put: (content, filename) ->
      (ctx, cb) =>
        content.getBuffer (data) =>
          @write("#{data.length} bytes to #{path.resolve(@_cwd, filename)}\n")
          fs.writeFile path.resolve(@_cwd, filename), data, cb

    get: (output, filename) ->
      (ctx, cb) =>
        fs.readFile path.resolve(@_cwd, filename), (err, data) =>
          return cb(err) if err
          @job.results[output] = @job.server.blobStore.putBlob(data, {from: 'file', jobId: @job.id, name: output}, cb)

    git_clone: (ref, dir) -> [
      @run('git', ['clone', '--', ref.repo, dir])
      @run('git', ['-C', dir, 'checkout', '-q', ref.ref])
    ]
