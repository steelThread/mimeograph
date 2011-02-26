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
# convenience
#
GLOBAL.file2redis = _.bind redisfs.file2redis, redisfs
GLOBAL.redis2file = _.bind redisfs.redis2file, redisfs

#
# Base class for mimeographs jobs.
#
class Job
  constructor: (@key, @callback) ->
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
  constructor: (@key, @callback, @text = '') ->
  extract: ->
    redis2file @key, file: @key, deleteKey: false, (err, file) =>
      return @fail err if err?
      log "extracting - #{file}"
      proc = spawn 'pdftotext', [file, '-']
      proc.stdout.on 'data', (data) => @text += data if data?
      proc.on 'exit', (code) =>
        return @fail "gs exit(#{code})" if code isnt 0
        @callback 
          key:  @key
          text: @text.toString().trim()
        delete @text

#
# Copy a file from redis to the filesystem.  The file is 
# split into individual .jpg files using gs.
#
# callback receives an array of all the split file paths
#
class Splitter  extends Job
  constructor: (@key, @callback, @pieces = []) ->
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
          @callback @pieces

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
      proc = spawn 'convert', ["-quiet", file, target]
      proc.on 'exit', (code) =>
        return @fail "convert exit(#{code})" unless code is 0
        @callback target

#
# OCR the tiff file and generate a text file for the result.
#
# callback receives the path the to text file.
#
class Recognizer extends Job
  recognize: ->
    redis2file @key, file: @key, (err, file) =>
      return @fail err if err?
      target = file.substr 0, file.indexOf '.'
      proc = spawn 'tesseract', [file, target]
      proc.on 'exit', (code) =>
        return @fail "tesseract exit(#{code})" if code isnt 0
        fs.readFile "#{target}.txt", (err, data) =>
          log "recognized - (#{data.length}) #{@key}"
          @callback "#{target}.txt"

#
# The resque jobs
#
jobs =
  extract   : (key, callback) -> new Extractor(key, callback).extract()
  split     : (key, callback) -> new Splitter(key, callback).split()
  convert   : (key, callback) -> new Converter(key, callback).convert()
  recognize : (key, callback) -> new Recognizer(key, callback).recognize()

#
# Manages the process.
#
class Mimeograph 
  constructor: (count = 5, @redis = redisfs.redis, @workers = []) ->
    @resque = resque.connect
      namespace: 'mimeograph'
      redis: @redis
    @worker i for i in [0...count]

  start: ->
    worker.start() for worker in @workers
    log.warn "Mimeograph started with #{@workers.length} workers."

  process: (file) ->
    @redis.incr 'mimeograph:job:id', (err, id) =>
      id = _.lpad id
      key = "/tmp/mimeograph-#{id}.pdf"
      @redis.set "mimeograh:job:#{id}:start", new Date().toISOString()
      file2redis file, key: key, deleteFile: false, (err, result) =>
        @enqueue 'extract', key
        log "OK - created mimeograph job:#{id} for file #{file}"
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
      # when 'recognize' 
      #   @redis.incr "mimeograh:job:#{id}:num_processed", result.length
      #   log "done, recognized #{result.length} chars"

  enqueue: (job, key) =>
    @resque.enqueue 'mimeograph', job, [key]

  store: (file, job) ->
    file2redis file, key: file, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      @enqueue job, file

  error: (error, worker, queue, job) ->
    log.err "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

  worker: (name) ->
    @workers.push worker = @resque.worker 'mimeograph', jobs
    worker.on 'error',   _.bind @error,   @
    worker.on 'success', _.bind @success, @
    worker

  end: ->
    log 'exiting...'
    worker.end() for worker in @workers
    if @resque? then @resque.end() else redisfs.end()

#
#  exports
#
mimeograph = exports
mimeograph.start   = (count = 5)-> new Mimeograph(count).start()
mimeograph.process = (filename) -> new Mimeograph().process filename
