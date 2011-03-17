mimeograph = exports
mimeograph.version = '0.1.0'

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
    redis2file @key, file: @key, deleteKey: false, (err, file) =>
      return @fail err if err?
      log "extracting - #{file}"
      proc = spawn 'pdftotext', [file, '-']
      proc.stdout.on 'data', (data) => @text += data if data?
      proc.on 'exit', (code) =>
        return @fail "gs exit(#{code})" if code isnt 0
        @complete text: @text.toString().trim()

#
# Copy a file from redis to the filesystem.  The file is
# split into individual .jpg files using gs.
#
# callback receives an array of all the split file paths
#
class Splitter  extends Job
  constructor: (@context, @callback, @pieces = []) ->
    super @context, @callback

  split: ->
    redis2file @key, file: @key, (err, file) =>
      return @fail err if err?
      target = file.substr 0, file.indexOf '.'
      log "splitting  - #{file}"
      proc = spawn 'gs', [
        '-SDEVICE=jpeg'
        '-r300x300'
        '-sPAPERSIZE=letter'
        "-sOutputFile=#{target}-%04d.jpg"
        '-dNOPAUSE'
        '--'
        file
      ]
      proc.on 'exit', (code) =>
        return @fail "gs exit(#{code})" if code isnt 0
        fs.readdir '/tmp', (err, files) =>
          @gather target, "#{candidate}" for candidate in files
          @complete pieces: @pieces

  gather: (target, filename) ->
    target = target.substr target.lastIndexOf('/') + 1
    @pieces.push "/tmp/#{filename}" if filename.match "^#{target}-{1}"

#
# Copy a file from redis to the filesystem.
# Converts the copied jpg files into tiff format.
#
# callback recieves the path to the tiff file.
#
class Converter extends Job
  convert: ->
    log "converting - #{@key}"
    redis2file @key, file: @key, (err, file) =>
      return @fail err if err?
      target = "#{file.substr 0, file.indexOf '.'}.tif"
      proc = spawn 'convert', ['-quiet', file, target]
      proc.on 'exit', (code) =>
        return @fail "convert exit(#{code})" if code isnt 0
        @complete file: target

#
# ocr or hocr the tif file and generate a text or markup file for the result.
#
# callback receives the path the to text file.
#
class Recognizer extends Job
  constructor: (@context, @callback, @ocr = true) ->
    super @context, @callback
    @suffix  = if @ocr then 'txt' else 'html'

  recognize: ->
    redis2file @key, file: @key, deleteKey: false, (err, file) =>
      return @fail err if err?
      target = file.substr 0, file.indexOf '.'
      args = [file, target]
      args.push 'hocr' if not @ocr
      proc = spawn 'tesseract', args
      proc.on 'exit', (code) =>
        return @fail "tesseract exit(#{code})" if code isnt 0
        fs.readFile "#{target}.#{@suffix}", (err, data) =>
          log "recognized - (ocr-#{data.length}) #{@key}" if @ocr
          log "recognized - (hocr-#{data.length}) #{@key}" if not @ocr
          @complete text: data, file: "#{target}.#{@suffix}"

#
# hocr2pdf the tif with the tesseract hocr result to produce a pdf
# with the text behind in a separate layer
#
class PageGenerator extends Job
  generate: ->
    log "pdf        - #{@key}"
    @complete {}
    redis2file @key, {file: @key, encoding: 'utf8'}, (err, file) =>
      return @fail err if err?
              
    
# class Stitcher

#
# The resque jobs
#
jobs =
  extract : (context, callback) -> new Extractor(context, callback).extract()
  split   : (context, callback) -> new Splitter(context, callback).split()
  convert : (context, callback) -> new Converter(context, callback).convert()
  ocr     : (context, callback) -> new Recognizer(context, callback).recognize()
  hocr    : (context, callback) -> new Recognizer(context, callback, off).recognize()
  pdf     : (context, callback) -> new PageGenerator(context, callback).generate()
#  stitch     : (context, callback) -> new Stitcher(context, callback).stitch()

#
# Manages the process.
#
class Mimeograph
  constructor: (count = 5, @redis = redisfs.redis, @workers = []) ->
    @resque = resque.connect
      namespace: 'resque:mimeograph'
      redis: @redis
    @worker i for i in [0...count]

  start: ->
    worker.start() for worker in @workers
    log.warn "Mimeograph started with #{@workers.length} workers."

  process: (file) ->
    @redis.incr 'mimeograph:job:id', (err, id) =>
      id = _.lpad id
      key = "/tmp/mimeograph-#{id}.pdf"
      @redis.set "mimeograph:job:#{id}:start", _.now()
      file2redis file, key: key, deleteFile: false, (err, result) =>
        @enqueue 'extract', key, id
        log.warn "OK - created job:#{id} for file #{file}"
        @end()

  success: (worker, queue, job, result) ->
    switch job.class
      when 'extract' then @split result
      when 'split'   then @convert result
      when 'convert' then @ocr result
      when 'ocr'     then @hocr result
      when 'hocr'    then @pdf result
      when 'pdf'     then @complete result

  split: (result) ->
    {key, id, text} = result
    if _.isEmpty text
      @enqueue 'split', key, id
    else
      @redis.set "mimeograph:job:#{id}:result.text", text
      @redis.del key

  convert: (result) ->
    {id, pieces} = result
    @redis.set "mimeograph:job:#{id}:num_pages", pieces.length
    @store file, 'convert', id for file in pieces

  ocr: (result) ->
    {id, file} = result
    @store file, 'ocr', id

  hocr: (result) ->
    {id, key, file, text} = result 
    @redis.zadd "mimeograph:job:#{id}:result.text", _.page(file), text
    @enqueue 'hocr', key, id
 
  pdf: (result) ->
    {id, file} = result
    file2redis file, {key: file, encoding: 'utf8'}, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      @enqueue 'pdf', file, id

  complete: (result) ->
    log 'complete   - are we done yet?'
    # file = result.file
    # page = file.substring file.lastIndexOf('-') + 1, file.indexOf '.'
    # multi = @redis.multi()
    # multi.zadd "mimeograh:job:#{result.id}:result", page, result.text
    # multi.incr "mimeograh:job:#{result.id}:num_processed"
    # multi.get  "mimeograh:job:#{result.id}:num_pages"
    # multi.exec (err, results) =>
    #   [processed, total] = results[1...]
    #   if processed is parseInt total
    #     log.warn "complete   - finished job:#{result.id}"
    #     @redis.set "mimeograh:job:#{result.id}:end", _.now()

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
    worker.on 'error',   _.bind @error,   @
    worker.on 'success', _.bind @success, @
    worker

  end: ->
    worker.end() for worker in @workers
    if @resque? then @resque.end() else redisfs.end()

#
#  exports
#
mimeograph.process = (filename) -> new Mimeograph().process filename
mimeograph.start   = (workers = 5) -> new Mimeograph(workers).start()
