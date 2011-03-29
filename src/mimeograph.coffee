mimeograph = exports
mimeograph.version = '0.1.2'

#
# Dependencies
#
fs            = require 'fs'
resque        = require 'coffee-resque'
{_, log}      = require './utils'
{redisfs}     = require 'redisfs'
{exec, spawn} = require 'child_process'

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
    file = "#{_.basename @key}.txt"
    fs.readFile file, 'utf8', (err, text) =>
      return @fail err if err?
      fs.unlink file
      @complete text: text.trim()

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
    proc = spawn 'tesseract', [@key, @basename]
    proc.on 'exit', (code) =>
      return @fail "tesseract exit(#{code})" if code isnt 0
      @fetchText()

  fetchText: ->
    fs.readFile @file, (err, text) =>
      return @fail err if err?
      fs.unlink @key
      fs.unlink @file
      @complete text: text, pageNumber: _.pageNumber @file

#
# The resque jobs.
#
jobs =
  extract : (context, callback) -> new Extractor(context, callback).perform()
  split   : (context, callback) -> new Splitter(context, callback).perform()
  ocr     : (context, callback) -> new Recognizer(context, callback).perform()

#
# Manages the process.
#
class Mimeograph
  constructor: (count, @workers = []) ->
    @resque = resque.connect
      redis     : redis
      namespace : 'resque:mimeograph'
    @worker i for i in [0...count]

  #
  # Start the workers.
  #
  start: ->
    worker.start() for worker in @workers
    log.warn "OK - mimeograph started with #{@workers.length} workers."

  #
  # Kick off a new job.
  #
  process: (file) ->
    fs.lstatSync file
    redis.incr @key('ids'), (err, id) =>
      return @capture err if err?
      @createJob _.lpad(id), file

  #
  # Creates a new mimeograph process job and
  # schedule an extract job.
  #
  createJob: (jobId, file) ->
    key = "/tmp/mimeograph-#{jobId}.pdf"
    redis.hset @key(jobId), 'started', _.now()
    file2redis file, key: key, deleteFile: false, (err) =>
      return @capture err, {jobId: jobId} if err?
      @enqueue 'extract', key, jobId
      log.warn "OK - created job:#{jobId} for file #{file}"
      @end()

  #
  # Rescue worker's success callback.
  # Orchestrates the job steps.
  #
  success: (worker, queue, job, result) ->
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
    if not text.length then @enqueue 'split', key, jobId
    else
      pages = text.split '\f'
      pages.pop()
      multi = redis.multi()
      multi.del key
      multi.hset @key(jobId), 'text', pages.join '\f'
      multi.exec (err) =>
        return @capture err, result if err?
        @finalize jobId

  #
  # Set the number of pages that came out of the
  # split step.  For each split file store the
  # the file in redis and schedule an ocr job.
  #
  ocr: (result) ->
    {jobId, pages} = result
    redis.hset @key(jobId), 'num_pages', pages.length, (err) =>
      return @capture err, result if err?
      @storeAndEnqueue page, 'ocr', jobId for page in pages

  #
  # Store the ocr data in a redis hash and determine
  # if all the pages have been recognized at which point
  # finish.
  #
  finish: (result) ->
    {jobId, pageNumber, text} = result
    multi = redis.multi()
    multi.hset    @key(jobId, 'text'), pageNumber, text, (err) =>
    multi.hincrby @key(jobId), 'num_processed', 1
    multi.hget    @key(jobId), 'num_pages'
    multi.exec (err, results) =>
      return @capture err, result if err?
      [processed, total] = results[1...]
      @finalize jobId if processed is parseInt total

  #
  # Wrap up the job.  
  #
  finalize: (jobId) ->
    @hash2key jobId, (err) =>
      return @capture err, result if err?
      multi = redis.multi()
      multi.hset @key(jobId), 'ended', _.now()
      multi.hdel @key(jobId), 'num_processed'
      multi.hdel @key(jobId), 'num_pages'
      multi.exec (err, results) =>
        return @capture err, result if err?
        log.warn "finished    - finished job:#{jobId}"

  #
  # Moves a hash to a key.  Fetches the entire hash,
  # sorts on the fields (page number) and pushes them
  # into a key into the job's hashs.
  #
  hash2key: (jobId, callback, pages = []) ->
    key = @key jobId, 'text'
    redis.hgetall key, (err, hash) =>
      return callback err, {jobId: jobId} if err?
      pages.push hash[field] for field in _.keys(hash).sort()
      multi = redis.multi()
      multi.del key
      multi.hset @key(jobId), 'text', pages.join '\f'
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
  # Resque worker's error handler.  Just log the error
  #
  error: (error, worker, queue, job) ->
    log.err "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

  #
  # Construct the named resque workers that carry out
  # the jobs.
  #
  worker: (name) ->
    @workers.push worker = @resque.worker 'mimeograph', jobs
    worker.name = "mimeograph:#{name}"
    worker.on 'error',   _.bind @error,   @
    worker.on 'success', _.bind @success, @
    worker

  #
  # All done, disconnect the redis client.
  #
  end: ->
    worker.end() for worker in @workers
    if @resque? then @resque.end() else redisfs.end()

  #
  # Namespace util for redis key gen.
  #
  key: (args...) ->
    args.unshift "mimeograph:job"
    args.join ':'

  #
  # Log the err.
  #
  # todo: add the jobId here and error notification.
  #
  capture: (err, meta) -> log.err "#{JSON.stringify meta} #{JSON.stringify err}"

#
# exports
#
mimeograph.process = (file)        -> new Mimeograph().process file
mimeograph.start   = (workers = 5) -> new Mimeograph(workers).start()
