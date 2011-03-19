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
# module scoped redis client instance
#
redis = redisfs.redis

#
# convenience
#
GLOBAL.file2redis = _.bind redisfs.file2redis, redisfs
GLOBAL.redis2file = _.bind redisfs.redis2file, redisfs

#
# Base class for mimeograph jobs.
#
class Job
  constructor: (@context, @callback) ->
    @key = @context.key

  complete: (result) ->
    @callback _.extend @context, result

  fail: (err) ->
    @callback if _.isString err then new Error err else err

#
# Copy a file from redis to the filesystem and run pdf2text.
# Results are accumulated. If the accumulated result is empty
# then ocr needs to occur.
#
# callback will receive a hash with a text and key fields.
#
class Extractor extends Job
  constructor: (@context, @callback, @text = '') ->
    super @context, @callback

  extract: ->
    redis2file @key, file: @key, deleteKey: false, (err) =>
      return @fail err if err?
      log "extracting - #{@key}"
      proc = spawn 'pdftotext', [@key, '-']
      proc.stdout.on 'data', (data) => @text += data if data?
      proc.on 'exit', (code) =>
        return @fail "pdftotext exit(#{code})" if code isnt 0
        @complete text: @text.toString().trim()

#
# Copy a file from redis to the filesystem.  The file is
# split into individual .jpg files using gs.
#
# callback receives an array of all the split file paths
#
class Splitter  extends Job
  constructor: (@context, @callback, @pages = []) ->
    super @context, @callback
 
  split: ->
    redis2file @key, file: @key, (err) =>
      return @fail err if err?
      basename = _.basename @key
      log "splitting  - #{@key}"
      proc = spawn 'gs', [
        '-SDEVICE=jpeggray'
        '-r300x300'
        '-sPAPERSIZE=letter'
        "-sOutputFile=#{basename}-%04d.jpg"
        '-dNOPAUSE'
        '-dSAFER'
        '--'
        @key
      ]
      proc.on 'exit', (code) =>
        return @fail "gs exit(#{code})" if code isnt 0
        fs.readdir '/tmp', (err, candidates) =>
          @gather basename, "#{candidate}" for candidate in candidates
          @complete pages: @pages

  gather: (basename, filename) ->
    basename = basename.substr basename.lastIndexOf('/') + 1
    @pages.push "/tmp/#{filename}" if filename.match "^#{basename}-{1}"

#
# ocr or hocr the tif file and generate a text or markup file for the result.
#
# callback receives the data and path to the generated file.
#
class Recognizer extends Job
  constructor: (@context, @callback, @ocr = true) ->
    super @context, @callback
    @extension  = if @ocr then 'txt' else 'html'

  recognize: ->
    redis2file @key, {file: @key, deleteKey: false}, (err) =>
      return @fail err if err?
      basename = _.basename @key
      args = [@key, basename]
      args.push 'hocr' unless @ocr
      proc = spawn 'tesseract', args
      proc.on 'exit', (code) =>
        return @fail "tesseract exit(#{code})" if code isnt 0
        file = "#{basename}.#{@extension}"
        fs.readFile file, (err, data) =>
          log "recognized - #{if @ocr then '(ocr)' else '(hocr)'} #{@key}"
          fs.unlink @key if @ocr
          @complete text: data, file: file

#
# hocr2pdf the tif with the tesseract hocr result to produce a pdf
# with the text behind in a separate layer
#
class PageGenerator extends Job
  generate: ->
    basename = _.basename @key
    redis2file @key, {file: @key, encoding: 'utf8'}, (err) =>
      return @fail err if err?
      img  = "#{basename}.jpg"
      redis2file img, file: img, (err) =>
        return @fail err if err?
        pdf  = "#{basename}.pdf"
        proc = exec "hocr2pdf -i #{img} -o #{pdf} < #{@key}"
        proc.on 'exit', (code) =>
          return @fail "hocr2pdf exit(#{code})" if code isnt 0
          fs.readFile pdf, 'base64', (err, data) =>
            log "pdf        - #{pdf}"
            fs.unlink file for file in [img, pdf, @key]
            @complete pdf: data, file: pdf

#
# Stitches together the individual pdf pages
#
class Stitcher extends Job
  constructor: (@context, @callback) ->
    super @context, @callback
    @file = "/tmp/mimeograph-#{@context.id}.pdf"
    @args = [
      '-q'
      '-sPAPERSIZE=letter'
      '-dNOPAUSE'
      '-dBATCH'
      '-SDEVICE=pdfwrite'
      "-sOutputFile=#{@file}"
    ]

  stitch: ->
    log "stitching  - #{@key}"
    @fetch (files) =>
      proc = spawn 'gs', @args.concat files
      proc.on 'exit', (code) =>
        return @fail "stitch exit(#{code})" if code isnt 0
        redis.del @key
        fs.unlink file for file in files
        @complete file: @file

  fetch: (callback, i = 0, files = []) ->
    redis.zrange @key, 0, -1, (err, elements) =>
      return @fail err if err?
      for file in elements
        files.push path = "/tmp/mimeograph-#{@context.id}-#{_.lpad ++i, 4}.pdf"
        fs.writeFileSync path, file, 'base64'    
      callback files

#
# The resque jobs
#
jobs =
  extract : (context, callback) -> new Extractor(context, callback).extract()
  split   : (context, callback) -> new Splitter(context, callback).split()
  ocr     : (context, callback) -> new Recognizer(context, callback).recognize()
  hocr    : (context, callback) -> new Recognizer(context, callback, off).recognize()
  pdf     : (context, callback) -> new PageGenerator(context, callback).generate()
  stitch  : (context, callback) -> new Stitcher(context, callback).stitch()

#
# Manages the process.
#
class Mimeograph
  constructor: (count = 5, @workers = []) ->
    @resque = resque.connect
      namespace : 'resque:mimeograph'
      redis     : redis
    @worker i for i in [0...count]

  start: ->
    worker.start() for worker in @workers
    log.warn "Mimeograph started with #{@workers.length} workers."

  process: (file) ->
    fs.lstatSync file
    redis.incr @key('id'), (err, id) =>
      id  = _.lpad id
      key = "/tmp/mimeograph-#{id}.pdf"
      redis.set @key(id, 'started'), _.now()
      file2redis file, {key: key, deleteFile: false}, (err) =>
        @enqueue 'extract', key, id
        log.warn "OK - created job:#{id} for file #{file}"
        @end()

  success: (worker, queue, job, result) ->
    switch job.class
      when 'extract' then @split result
      when 'split'   then @ocr result
      when 'ocr'     then @hocr result
      when 'hocr'    then @pdf result
      when 'pdf'     then @complete result
      when 'stitch'  then @finish result

  split: (result) ->
    {id, key, text} = result
    if _.isEmpty text
      @enqueue 'split', key, id
    else
      redis.zadd @key(id, 'text'), 0, text
      redis.del key

  ocr: (result) ->
    {id, pages} = result
    redis.set @key(id, 'num_pages'), pages.length
    @store page, 'ocr', id for page in pages

  hocr: (result) ->
    {id, key, file, text} = result
    redis.zadd @key(id, 'text'), _.rank(file), text
    @enqueue 'hocr', key, id

  pdf: (result) ->
    {id, file} = result
    file2redis file, {key: file, encoding: 'utf8'}, (err) =>
      return log.err "#{JSON.stringify err}" if err?
      @enqueue 'pdf', file, id

  complete: (result) ->
    {id, file, pdf} = result
    multi = redis.multi()
    multi.zadd @key(id, 'pages'), _.rank(file), pdf
    multi.incr @key(id, 'num_processed')
    multi.get  @key(id, 'num_pages')
    multi.exec (err, results) =>
      [processed, total] = results[1...]
      if processed is parseInt total
        redis.del [
          @key(id, 'num_processed')
          @key(id, 'num_pages')
        ]
        @stitch result

  stitch: (result) ->
    {id} = result
    @enqueue 'stitch', @key(id, 'pages'), id

  finish: (result) ->
    {id, file} = result
    file2redis file, key: @key(id, 'pdf'), (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      redis.set @key(id, 'ended'), _.now()
      log.warn "finished   - finished job:#{id}"

  enqueue: (job, key, id) =>
    @resque.enqueue 'mimeograph', job, [{key: key, id: id}]

  store: (file, job, id) ->
    file2redis file, key: file, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      @enqueue job, file, id

  error: (error, worker, queue, job) ->
    log.err "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

  worker: (name) ->
    @workers.push worker = @resque.worker 'mimeograph', jobs
    worker.name = "mimeograph:#{name}"
    worker.on 'error',   _.bind @error,   @
    worker.on 'success', _.bind @success, @
    worker

  end: ->
    worker.end() for worker in @workers
    if @resque? then @resque.end() else redisfs.end()

  key: (args...) ->
    args.unshift "mimeograph:job"
    args.join ':'

#
#  exports
#
mimeograph.process = (filename)    -> new Mimeograph().process filename
mimeograph.start   = (workers = 5) -> new Mimeograph(workers).start()