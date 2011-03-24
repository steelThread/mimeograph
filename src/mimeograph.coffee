mimeograph = exports
mimeograph.version = '0.1.0'

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
      '-SDEVICE=jpeggray'
      '-r300x300'
      '-sPAPERSIZE=letter'
      "-sOutputFile=#{@basename}-%04d.jpg"
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
# Recognize (ocr or hocr) the text from the jpg images using
# tesseract.
#
# callback will receive a hash with a 'text' field containing
# the ocr/hocr text and a 'file' field containing the path to
# the result.
#
class Recognizer extends Job
  constructor: (@context, @callback, @ocr = true) ->
    super @context, @callback
    @basename  = _.basename @key
    @file      = "#{@basename}.#{if @ocr then 'txt' else 'html'}"

  perform: ->
    log "recognizing - #{if @ocr then '(ocr)' else '(hocr)'} #{@key}"
    redis2file @key, {file: @key, deleteKey: false}, (err) =>
      return @fail err if err?
      @recognize()

  recognize: ->
    args = [@key, @basename]
    args.push 'hocr' unless @ocr
    proc = spawn 'tesseract', args
    proc.on 'exit', (code) => 
      return @fail "tesseract exit(#{code})" if code isnt 0
      @fetchText()

  fetchText: ->
    fs.readFile @file, (err, text) =>
      fs.unlink @key
      fs.unlink @file if @ocr
      @complete text: text, file: @file

#
# Generate a searchable pdf page using hocr2pdf.
#
# callback will receive a hash with a 'pdf' field containing
# the base64 encoded contents of the resulting pdf file and a 
# 'file' field containing the path to the result.
#
class PageGenerator extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @basename = _.basename @key
    @img = "#{@basename}.jpg"
    @pdf = "#{@basename}.pdf"
  
  perform: ->
    log "generating  - #{@pdf}"
    redis2file @key, {file: @key, encoding: 'utf8'}, (err) =>
      return @fail err if err?
      redis2file @img, file: @img, (err) => 
        return @fail err if err?
        @generate()

  generate: ->
    proc = exec "hocr2pdf -i #{@img} -o #{@pdf} < #{@key}"
    proc.on 'exit', (code) => 
      return @fail "hocr2pdf exit(#{code})" if code isnt 0
      @fetchPage()

  fetchPage: ->
    fs.readFile @pdf, 'base64', (err, content) =>
      fs.unlink file for file in [@img, @pdf, @key]
      @complete page: content, file: @pdf

#
# Stitch together the individual pdf pages containing the text-behind 
# into a single pdf file.
#
# callback will receive a hash with a 'file' field containing the 
# path to the resulting pdf.
#
class Stitcher extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @pdf = "/tmp/mimeograph-#{@jobId}.pdf"
    @args = [
      '-q'
      '-sPAPERSIZE=letter'
      '-dNOPAUSE'
      '-dBATCH'
      '-SDEVICE=pdfwrite'
      "-sOutputFile=#{@pdf}"
    ]

  perform: ->
    log "stitching   - #{@key}"
    @fetchFiles (files) => @stitch files

  stitch: (files) ->
    proc = spawn 'gs', @args.concat files
    proc.on 'exit', (code) =>
      return @fail "stitch exit(#{code})" if code isnt 0
      redis.del @key
      fs.unlink file for file in files
      @complete file: @pdf
	
  fetchFiles: (callback, i = 0, files = []) ->
    redis.lrange @key, 0, -1, (err, elements) =>
      return @fail err if err?
      for file in elements
        files.push path = "/tmp/mimeograph-#{@jobId}-#{_.lpad ++i, 4}.pdf"
        fs.writeFileSync path, file, 'base64'
      callback files

#
# The resque jobs.
#
jobs =
  extract : (context, callback) -> new Extractor(context, callback).perform()
  split   : (context, callback) -> new Splitter(context, callback).perform()
  ocr     : (context, callback) -> new Recognizer(context, callback).perform()
  hocr    : (context, callback) -> new Recognizer(context, callback, off).perform()
  pdf     : (context, callback) -> new PageGenerator(context, callback).perform()
  stitch  : (context, callback) -> new Stitcher(context, callback).perform()

#
# Manages the process.
#
class Mimeograph
  constructor: (count = 5, @workers = []) ->
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
      jobId  = _.lpad id
      key = "/tmp/mimeograph-#{jobId}.pdf"
      redis.set @key(jobId, 'started'), _.now()
      file2redis file, {key: key, deleteFile: false}, (err) =>
        @enqueue 'extract', key, jobId
        log.warn "OK - created job:#{jobId} for file #{file}"
        @end()

  #
  # Rescue worker success callback.  
  # Orchestrates the job steps.
  #
  success: (worker, queue, job, result) ->
    switch job.class
      when 'extract' then @split result
      when 'split'   then @ocr result
      when 'ocr'     then @hocr result
      when 'hocr'    then @pdf result
      when 'pdf'     then @stitch result
      when 'stitch'  then @finish result

  #
  # Schedule a split job if ocr is required, 
  # ie the extract step didn't produce any text.
  # If ocr isn't required job is finished and
  # the text is set in the text key for the
  # job.
  #
  split: (result, i = 0) ->
    {jobId, key, text} = result
    if not text.length then @enqueue 'split', key, jobId
    else
      pages = text.split '\f'
      pages.pop()
      multi = redis.multi()
      multi.del key
      multi.rpush @key(jobId, 'text'), page for page in pages
      multi.exec (err) =>
        return log.err "#{JSON.stringify err}" if err?
        @finish _.extend result, file: key

  #
  # Set the number of pages that came out of the
  # split step.  For each split file store the
  # the file in redis and schedule an ocr job.
  #
  ocr: (result) ->
    {jobId, pages} = result
    redis.set @key(jobId, 'num_pages'), pages.length
    @storeAndEnqueue page, 'ocr', jobId for page in pages

  #
  # Store the result of the ocr into a redis hash 
  # at the job's text key ans schedule an hocr job.
  #
  hocr: (result) ->
    {jobId, key, file, text} = result
    redis.hset @key(jobId, 'text'), _.pageNumber(file), text
    @enqueue 'hocr', key, jobId

  #
  # Store the hocr result in redis and schedule a pdf
  # job.
  #
  pdf: (result) ->
    {jobId, file} = result
    @storeAndEnqueue file, 'utf8', 'pdf', jobId

  #
  # Store the pdf data in a redis hash and determine
  # if all the pages have been created at which point
  # schedule a stitch job
  #
  stitch: (result) ->
    {jobId, file, page} = result
    multi = redis.multi()
    multi.hset @key(jobId, 'pages'), _.pageNumber(file), page
    multi.incr @key(jobId, 'num_processed')
    multi.get  @key(jobId, 'num_pages')
    multi.exec (err, results) =>
      [processed, total] = results[1...]
      if processed is parseInt total
        @hash2list jobId, 'pages', =>
          redis.del [
            @key jobId, 'num_processed'
            @key jobId, 'num_pages'
          ]
          @enqueue 'stitch', @key(jobId, 'pages'), jobId

  #
  # Store the resulting pdf in the job's pdf key.
  #
  # todo:  notify via pub/sub that the job is complete
  #        and ready to be further processed.
  #
  finish: (result) ->
    {jobId, file} = result
    @hash2list jobId, 'text', =>
      file2redis file, key: @key(jobId, 'pdf'), (err) =>
        return log.err "#{JSON.stringify err}" if err?
        redis.set @key(jobId, 'ended'), _.now()
        log.warn "finished    - finished job:#{jobId}"

  #
  # Moves a hash into a list.  Fetches the entire hash,
  # sorts on the fields (page number) and pushes them
  # into a list for the original key.
  #
  hash2list: (jobId, key, callback) ->
    key = @key jobId, key
    redis.hgetall key, (err, hash) =>
      multi = redis.multi()
      multi.del key
      multi.rpush key, hash[field] for field in _.keys(hash).sort()
      multi.exec (err, results) => callback()

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
      return log.err "#{JSON.stringify err}" if err?
      @enqueue job, file, jobId

  #
  # Resque worker's error handler.  Just log the error
  #
  error: (error, worker, queue, job) ->
    log.err "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

  #
  # Construct the named resque workers that carry out the jobs.
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
# exports
#
mimeograph.process = (filename)    -> new Mimeograph().process filename
mimeograph.start   = (workers = 5) -> new Mimeograph(workers).start()
