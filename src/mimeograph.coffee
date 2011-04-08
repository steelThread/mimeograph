mimeograph = exports
mimeograph.version = '0.1.3'

#
# Dependencies
#
fs             = require 'fs'
resque         = require 'coffee-resque'
{spawn}        = require 'child_process'
{redisfs}      = require 'redisfs'
{_, log, puts} = require './utils'

#
# module scoped redisfs instance
#
redisfs = redisfs
  namespace : 'mimeograph'
  prefix    : 'mimeograph-'
  encoding  : 'base64'

#
# module scoped utils
#
redis      = redisfs.redis
file2redis = _.bind redisfs.file2redis, redisfs
redis2file = _.bind redisfs.redis2file, redisfs

#
# @abstract
# Base class for mimeograph jobs.
#
class Job
  constructor: (@context, @callback) ->
    {@key, @jobId} = @context

  complete: (result) ->
    @callback _.extend @context, result

  fail: (err) ->
    @callback if _.isString err then new Error err else err

#
# Extract the text from the pdf using pdftotext.
#
# callback will receive a hash with a 'text' field containing
# the accumlated text found in the pdf.
#
class Extractor extends Job
  perform: ->
    log "extracting  - #{@key}"
    redis2file @key, file: @key, deleteKey: false, (err) =>
      return @fail err if err?
      @extract()

  extract: ->
    proc = spawn 'pdftotext', [@key]
    proc.on 'exit', (code) =>
      return @fail "pdftotext exit(#{code})" if code isnt 0
      @fetchText()

  fetchText: ->
    @file = "#{_.basename @key}.txt"
    fs.readFile @file, 'utf8', (err, text) =>
      return @fail err if err?
      fs.unlink file for file in [@file, @key]
      @complete text: text

#
# Split the pdf file into individual .jpg files using
# ghostscript.
#
# callback will receive a hash with a 'pages' propery
# containing and array of all the paths produced by
# ghostscript.
#
class Splitter  extends Job
  constructor: (@context, @callback, @pages = []) ->
    super @context, @callback
    @basename = _.basename @key
    @args = [
      '-SDEVICE=pnggray'
      '-r600x600'
      '-sPAPERSIZE=letter'
      "-sOutputFile=#{@basename}-%04d.png"
      '-dTextAlphaBits=4'
      '-dBATCH'
      '-dNOPAUSE'
      '-dSAFER'
      '--'
      @key
    ]

  perform: ->
    log "splitting   - #{@key}"
    redis2file @key, file: @key, (err) =>
      return @fail err if err?
      @split()

  split: ->
    proc = spawn 'gs', @args
    proc.on 'exit', (code) =>
      return @fail "gs exit(#{code})" if code isnt 0
      @fetchPages()

  fetchPages: ->
    fs.readdir '/tmp', (err, files) =>
      return @fail err if err?
      @findPages @basename, "#{file}" for file in files
      fs.unlink @key
      @complete pages: @pages

  findPages: (basename, file) ->
    basename = basename.substr basename.lastIndexOf('/') + 1
    @pages.push "/tmp/#{file}" if file.match "^#{basename}-{1}"

#
# Recognize (ocr) the text from the jpg images using
# tesseract.
#
# callback will receive a hash with a 'text' field containing
# the ocr text and a 'file' field containing the path to
# the result.
#
class Recognizer extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @basename  = _.basename @key
    @file      = "#{@basename}.txt"

  perform: ->
    log "recognizing - #{@key}"
    redis2file @key, file: @key, (err) =>
      return @fail err if err?
      @recognize()

  recognize: ->
    jobStatus @jobId, (status) =>
      if status isnt 'fail'
        proc = spawn 'tesseract', [@key, @basename]
        proc.on 'exit', (code) =>
          return @fail "tesseract exit(#{code})" if code isnt 0
          @fetchText()
      else
        fs.unlink @key
        @complete()

  fetchText: ->
    fs.readFile @file, (err, text) =>
      return @fail err if err?
      fs.unlink file for file in [@key, @file]
      @complete text: text, pageNumber: _.pageNumber @file

#
# The resque jobs.
#
jobs =
  extract : (context, callback) -> new Extractor(context, callback).perform()
  split   : (context, callback) -> new Splitter(context, callback).perform()
  ocr     : (context, callback) -> new Recognizer(context, callback).perform()

#
# Namespace util for redis key gen.
#
genkey = (args...) ->
  args.unshift "mimeograph:job"
  args.join ':'

#
# Get a jobs status
#
jobStatus = (jobId, callback) ->
  redis.hget genkey(jobId), 'status', (err, status) =>
    callback status

#
# Manages the process.
#
class Mimeograph
  constructor: (count, @workers = []) ->
    @resque = resque.connect
      redis     : redis
      namespace : 'resque:mimeograph'
    @worker i for i in [0...count]
    process.on 'SIGINT',  @end
    process.on "SIGTERM", @end
    process.on "SIGQUIT", @end
  #
  # Start the workers.
  #
  start: ->
    worker.start() for worker in @workers
    log.warn "OK - mimeograph started with #{@workers.length} workers."

  #
  # Kick off a new job.
  #
  process: (id, file) ->
    try 
      status = fs.lstatSync file
      throw Error "'#{file}' is not a file." unless status.isFile()
      if id? then @createJob id, file
      else redis.incr genkey('ids'), (err, id) =>
        return @capture err if err?
        @createJob _.lpad(id), file
    catch error
      puts.stderr "#{error.message}"
      @end()

  #
  # Creates a new mimeograph process job and
  # schedule an extract job.
  #
  createJob: (jobId, file) ->
    key = @filename jobId
    redis.hset genkey(jobId), 'started', _.now()
    file2redis file, key: key, deleteFile: false, (err) =>
      return @capture err, {jobId: jobId} if err?
      @enqueue 'extract', key, jobId
      puts.green "OK - created #{genkey(jobId)} for file #{file}"
      @end()

  #
  # Generate a file name.
  #
  filename: (jobId) ->
    "/tmp/mimeograph-#{jobId}.pdf"

  #
  # Rescue worker's success callback.
  # Orchestrates the job steps.
  #
  success: (worker, queue, job, result) =>
    switch job.class
      when 'extract' then @split result
      when 'split'   then @ocr result
      when 'ocr'     then @finish result

  #
  # Schedule a split job if ocr is required,
  # ie the extract step didn't produce any text.
  # If ocr isn't required job is finished and
  # the text is set in the text key for the
  # job.
  #
  split: (result) ->
    {jobId, key, text} = result
    if not text.trim().length 
      @enqueue 'split', key, jobId
    else
      multi = redis.multi()
      multi.del  key
      multi.hset genkey(jobId), 'text', text
      multi.exec (err, result) =>
        return @capture err, result if err?
        @finalize jobId

  #
  # Set the number of pages that came out of the
  # split step.  For each split file store the
  # the file in redis and schedule an ocr job.
  #
  ocr: (result) ->
    {jobId, pages} = result
    redis.hset genkey(jobId), 'num_pages', pages.length, (err) =>
      return @capture err, result if err?
      @storeAndEnqueue page, 'ocr', jobId for page in pages

  #
  # Store the ocr data in a redis hash and determine
  # if all the pages have been recognized at which point
  # finish.
  #
  finish: (result) ->
    {jobId, pageNumber, text} = result
    @shouldContinue jobId, =>
      multi = redis.multi()
      multi.hset    genkey(jobId, 'text'), pageNumber, text
      multi.hincrby genkey(jobId), 'num_processed', 1
      multi.hget    genkey(jobId), 'num_pages'
      multi.exec (err, results) =>
        return @capture err, result if err?
        [processed, total] = results[1...]
        @checkComplete jobId, processed, parseInt total

  #
  # Determine if all the pages have been processed and
  # finalize if so.
  #
  checkComplete: (jobId, processed, total) ->
    if processed is total
      @hash2key jobId, (err) =>
        return @capture err, result if err?
        @finalize jobId

  #
  # Wrap up the job and publish a notification
  #
  finalize: (jobId) ->
    job = genkey jobId
    multi = redis.multi()
    multi.hset job, 'ended', _.now()
    multi.hset job, 'status', 'success'
    multi.hdel job, 'num_processed'
    multi.exec (err, results) =>
      return @capture err, result if err?
      log.warn "finished    - #{job}"
      @notify job

  #
  # Attempt to notify clients about job completness.
  # In the event where there were no subscribers
  # add the job to the completed set.  Sort of a poor
  # mans durability solution.
  #
  notify: (job, status = 'success') ->
    redis.publish job, "#{job}:#{status}", (err, subscribers) =>
      return @capture err, result if err?
      redis.sadd genkey('completed'), job  unless subscribers

  #
  # Moves a hash to a key.  Fetches the entire hash,
  # sorts on the fields (page number) and pushes them
  # into a key into the job's hashs.
  #
  hash2key: (jobId, callback, pages = []) ->
    key = genkey jobId, 'text'
    redis.hgetall key, (err, hash) =>
      return callback err, {jobId: jobId} if err?
      pages.push hash[field] for field in _.keys(hash).sort()
      multi = redis.multi()
      multi.del  key
      multi.hset genkey(jobId), 'text', pages.join '\f'
      multi.exec (err) => callback err

  #
  # Pushes a job onto the queue.  Each job receives a
  # context which includes the id of the job being
  # processed and a key which usually points to a file
  # in redis that is required by the job to carry out
  # it's work.
  #
  enqueue: (job, key, jobId) ->
    @resque.enqueue 'mimeograph', job, [
      key   : key
      jobId : jobId
    ]

  #
  # Store a file in redis and schedule a job.
  #
  storeAndEnqueue: (file, encoding..., job, jobId) ->
    options = key: file
    options.encoding = encoding.shift() unless _.isEmpty encoding
    file2redis file, options, (err) =>
      return @capture err, {jobId: jobId, job: job} if err?
      @enqueue job, file, jobId

  #
  # Resque worker's error handler.  Fail the job, bookeeping
  # and notification.
  #
  error: (error, worker, queue, job) =>
    jobId = job.args[0].jobId
    @shouldContinue jobId, =>
      log.err "Error processing job #{job.class} #{jobId}"
      multi = redis.multi()
      multi.hset genkey(jobId), 'status', 'fail'
      multi.hset genkey(jobId), 'error', JSON.stringify _.extend(job, error)
      multi.del  genkey(jobId, 'text') if job.class is 'ocr'
      multi.del  @filename jobId if job.class is 'extract'
      multi.exec (err) =>
        return @capture err, {jobId: jobId} if err?
        @notify genkey(jobId), 'fail'

  #
  # Construct the named resque workers that carry out
  # the jobs.
  #
  worker: (name) ->
    @workers.push worker = @resque.worker 'mimeograph', jobs
    worker.name = "mimeograph:#{name}"
    worker.on 'error',   @error
    worker.on 'success', @success
    worker

  #
  # All done, disconnect the redis client.
  #
  end: =>
    log.warn 'Shutting down!'
    worker.end() for worker in @workers
    if @resque? then @resque.end() else redisfs.end()

  #
  # Continuation.  When the job has not failed the callback
  # will be invoked.
  #
  shouldContinue: (jobId, callback) ->
    jobStatus jobId, (status) =>
      callback() if status isnt 'fail'

  #
  # Log the err.
  #
  # todo: add the jobId here and error notification.
  #
  capture: (err, meta) -> log.err "#{JSON.stringify meta} #{JSON.stringify err}"

#
# exports
#
mimeograph.process = (args) ->
  id   = args.shift() if args.length is 2
  file = args.shift()
  new Mimeograph().process id, file

mimeograph.start = (workers = 5) ->
  new Mimeograph(workers).start()
