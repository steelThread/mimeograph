exports.version = '0.1.0'

#
# Dependencies
#
fs             = require 'fs'
resque         = require 'coffee-resque'
{spawn}        = require 'child_process'
{redisfs}      = require 'redisfs'
{EventEmitter} = require 'events'
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
      return @callback err if err?
      log "extracting - #{file}"
      proc = spawn 'pdftotext', [file, '-']
      proc.stdout.on 'data', (data) => @text.accumulate data
      proc.on 'exit', (code) =>
        return @callback new Error "gs exit(#{code})" unless code is 0
        @callback 
          text: @text.value.toString().trim()
          key:  @key
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
      return @callback err if err?
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
        return @callback new Error "gs exit(#{code})" unless code is 0
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
      return @callback err if err?
      target = "#{file.substr 0, file.indexOf '.'}.tif"
      proc = spawn 'convert', ["-quiet", file, target]
      proc.on 'exit', (code) =>
        return callback new Error "convert exit(#{code})" unless code is 0
        @callback target

#
# Convert to a txt file.
#
class Recognizer extends Job
  recognize: ->
    redisfs.redis2file @key, filename: @key, (err, file) =>
      return @callback err if err?
      target = file.substr 0, file.indexOf '.'
      proc = spawn 'tesseract', [file, target]
      proc.on 'exit', (code) =>
        return callback new Error "tesseract exit(#{code})" unless code is 0
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
class Mimeograph extends EventEmitter
  constructor: (@redis = redisfs.redis) ->
    @conn = resque.connect namespace: 'mimeograph', redis: @redis

  start: ->
    log 'starting...'
    @worker = @conn.worker 'mimeograph', jobs
    @worker.on 'error',   _.bind @error,   @
    @worker.on 'success', _.bind @success, @
    @worker.start()

  request: (file) ->
    @id (id) =>
      log "request - creating job #{id} for file #{file}"
      key = "/tmp/mimeograph-#{id}.pdf"
      @redis.set "mimeograh:job:#{id}:start", new Date().toISOString()
      redisfs.file2redis file, {key: key, deleteFile: false}, (err, result) =>
        @enqueue 'extract', key
        @end()

  success: (worker, queue, job, result) ->
    switch job.class
      when 'extract'
        if _.isEmpty result.text then @enqueue 'split', result.key
        else
          @redis.del key
          @end()
      when 'split'
        for file in result
          @store file, (key) => @enqueue 'convert', key
      when 'convert'
        @store result, (key) => @enqueue 'recognize', key
      # when 'recognize'
      #   log "done, recognized #{result.length} chars"

  id: (callback) ->
    @redis.incr 'mimeograph:job:id', (err, id) =>
      callback _.lpad id    
    
  enqueue: (job, key) =>
    @conn.enqueue 'mimeograph', job, [key]

  store: (filename, callback) ->
    redisfs.file2redis filename, key: filename, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      callback result.key

  error: (error, worker, queue, job) ->
    log "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"
    @end()

  end: ->
    log 'bye bye'
    redisfs.end() unless @conn
    @worker.end() if @worker?
    @conn.end()   if @conn?
    process.exit()

#
#  exports
#
exports.start   = -> new Mimeograph().start()
exports.request = (filename) -> 
  mimeograph = new Mimeograph()
  mimeograph.request filename