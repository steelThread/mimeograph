exports.version = '0.1.0'

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
# Beyond simple accumulator
#
class Accumulator
  constructor: (@value = '') ->
  accumulate:  (data) -> @value += data if data?

#
# Base class for mimeographs jobs aka processing steps.
#
class Job
  constructor: (@key, @callback) ->
  fail: (err) ->
    @callback if _.isString err then new Error err else err
    
#
# Copy a file from redis to the filesystem and run pdf2text.
# Results are accumulated. If the accumulated result is empty
# then ocr needs to occur so split else done. For this operation
# the original file contents will remain in redis.
#
# Callback will receive the extracted text from the pdf.
#
class Extractor extends Job
  constructor: (@key, @callback, @text = new Accumulator()) -> 
  extract: ->
    redisfs.redis2file @key, {filename: @key, deleteKey: false}, (err, file) =>
      return @fail err if err?
      log "extracting - #{file}"
      proc = spawn 'pdftotext', [file, '-']
      proc.stdout.on 'data', (data) => @text.accumulate data
      proc.on 'exit', (code) =>
        return @fail "gs exit(#{code})" unless code is 0
        @callback 
          key:  @key
          text: @text.value.toString().trim()
        delete @text

#
# Copy a file (original from extractor phase) from redis
# to the filesystem.  The file is split into individual
# .jpg files us gs.  Each resulting filename is passed
# to the callback.
#
# TODO The callback model here will need to change!
# The correct protocol between resque and workers is to make
# a single callback.  Would be best to accumulate the results
# and pass that to the callback.
#
class Splitter  extends Job
  constructor: (@key, @callback, @pieces = []) ->
  split: ->
    redisfs.redis2file @key, filename: @key, (err, file) =>
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
        return @fail "gs exit(#{code})" unless code is 0
        fs.readdir '/tmp', (err, files) =>
          @gather target, "#{candidate}" for candidate in files
          @callback @pieces

  gather: (target, filename) -> 
    target = target.substr target.lastIndexOf('/') + 1
    @pieces.push "/tmp/#{filename}" if filename.match "^#{target}-{1}"

#
# Convert the jpg to a tif and pump back into redis.
#
class Converter extends Job
  convert: ->
    log "converting - #{@key}"
    redisfs.redis2file @key, filename: @key, (err, file) =>
      return @fail err if err?
      target = "#{file.substr 0, file.indexOf '.'}.tif"
      proc = spawn 'convert', ["-quiet", file, target]
      proc.on 'exit', (code) =>
        return @fail "convert exit(#{code})" unless code is 0
        @callback target

#
# Convert to a txt file.
#
class Recognizer extends Job
  recognize: ->
    redisfs.redis2file @key, filename: @key, (err, file) =>
      return @fail err if err?
      target = file.substr 0, file.indexOf '.'
      proc = spawn 'tesseract', [file, target]
      proc.on 'exit', (code) =>
        return @fail "tesseract exit(#{code})" unless code is 0
        fs.readFile "#{target}.txt", (err, data) =>
          log "recognized - (#{data.length}) #{@key}"
          @callback data

#
# The resque job callbacks
#
jobs =
  extract   : (filename, callback) -> new Extractor(filename, callback).extract()
  split     : (filename, callback) -> new Splitter(filename, callback).split()
  convert   : (filename, callback) -> new Converter(filename, callback).convert()
  recognize : (filename, callback) -> new Recognizer(filename, callback).recognize()

#
# Manages the process.
#
# Worker model needs to be overhauled.  We should talk about this more.
#
class Mimeograph 
  constructor: (@redis = redisfs.redis) ->
    @resque = resque.connect 
      namespace: 'mimeograph'
      redis: @redis

  start: ->
    log 'starting...'
    @worker = @resque.worker 'mimeograph', jobs
    @worker.on 'error',   _.bind @error,   @
    @worker.on 'success', _.bind @success, @
    @worker.start()

  request: (file) ->
    @redis.incr 'mimeograph:job:id', (err, id) =>
      id = _.lpad id
      key = "/tmp/mimeograph-#{id}.pdf"
      @redis.set "mimeograh:job:#{id}:start", new Date().toISOString()
      redisfs.file2redis file, {key: key, deleteFile: false}, (err, result) =>
        @enqueue 'extract', key
        log "OK - created job #{id} for file #{file}"
        @end()

  success: (worker, queue, job, result) ->
    switch job.class
      when 'extract'
        if _.isEmpty result.text then @enqueue 'split', result.key
        else
          @redis.del key
      when 'split'
        #@redis.set "mimeograh:job:#{id}:num_files", result.length
        @store file, 'convert' for file in result
      when 'convert'
        #@redis.incr "mimeograh:job:#{id}:num_processed", result.length
        @store result, 'recognize'
      #when 'recognize' then log "done, recognized #{result.length} chars"
    
  enqueue: (job, key) =>
    @resque.enqueue 'mimeograph', job, [key]

  store: (filename, job) ->
    redisfs.file2redis filename, key: filename, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      @enqueue job, filename

  error: (error, worker, queue, job) ->
    log "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

  end: ->
    log 'exiting...'
    if @resque then @resque.end() else redisfs.end()
    @worker.end() if @worker?

#
#  exports
#
exports.start   = -> new Mimeograph().start()
exports.request = (filename) -> new Mimeograph().request filename