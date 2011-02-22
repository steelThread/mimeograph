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
# Global redisfs instance
#
redisfs = redisfs 
  namespace: 'mimeograph'
  prefix: 'mimeograph-'
  encoding: 'base64'
  deleteFile: false

#
# Beyond simple accumulator
#
class Accumulator
  constructor: (@value = '') ->
  accumulate: (data) -> @value += data if data?

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
    super @key, @callback
      
  extract: ->
    log "(Extractor): extract #{@key}"
    redisfs.redis2file @key, deleteKey: false, (err, file) =>
      return @callback err if err?
      log "(Extractor): extract file #{file}"
      proc = spawn "pdftotext" , [file, "-"]
      proc.stdout.on "data", (data) => @text.accumulate data
      proc.stdout.on "end", =>
        @callback @text.value.toString().trim()
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
class Splitter extends Job
  constructor: (@key, @callback, @splits = []) ->
    super @key, @callback

  split: ->
    log "(Splitter): split #{@key}"
    redisfs.redis2file @key, (err, file) =>
      return @callback err if err?
      name = file.substr file.lastIndexOf('/') + 1
      log "(Splitter): splitting file: #{file}"
      proc = spawn "gs", [
        "-SDEVICE=jpeg" 
        "-r300x300"
        "-sPAPERSIZE=letter"
        "-sOutputFile=/tmp/#{name}_%04d.jpg"
        "-dNOPAUSE"
        "--"
        file
      ]
      proc.stdout.on "end", =>
        log "(Splitter): done."
        fs.readdir "/tmp", (err, files) =>
          @gather name, "#{candidate}" for candidate in files
          @callback @splits
                    
  gather: (basename, filename) ->
    @splits.push "/tmp/#{filename}" if filename.match "^#{basename}?.*jpg?$"
        
#
# Convert the jpg to a tif and pump back into redis.
#
class Converter extends Job
  convert: ->
    log "(Converter): convert #{@key}"
    redisfs.redis2file @key, (err, file) => 
      return @callback err if err?
      log.warn "Convert #{file}"
      name = file.substr file.lastIndexOf('/') + 1
      proc "convert", ["-quiet", file, "/tmp/#{name}.tif"]
      proc.on 'exit', =>
        @callback "/tmp/#{name}.tif"   

#
# Convert to a txt file.
#   
class Recognizer extends Job
  recognize: ->
    log "(Recognizer): recognize #{@key}"
    redisfs.redis2file @key, suffix:'.tif', (err, file) =>
      return @callback err if err?
      log "Recognize tif : #{file}"
      name = file.substr file.lastIndexOf('/') + 1
      name = name.substr 0, name.indexOf '.'
      log "plain name #{name}"
      proc "tesseract", [file, "/tmp/#{name}"]
      proc.on 'exit', (err) =>            
        return @callback err if err?
        fs.readFile "/tmp/#{name}.txt", 'utf8', (err, data) =>
          log "tesseract data for #{file}:#{data}"
          @callback data

#
# The resque job callbacks
#
jobs = 
  extract:   (filename, callback) -> new Extractor(filename, callback).extract() 
  split:     (filename, callback) -> new Splitter(filename, callback).split()
  convert:   (filename, callback) -> new Converter(filename, callback).convert()
  recognize: (filename, callback) -> new Recognizer(filename, callback).recognize()

#
# Manages the process.
#
# Worker model needs to be overhauled.  We should talk about this more.
#
class Mimeograph extends EventEmitter
  constructor: ->
    log "spinning up mimeograph"
    @conn = resque.connect namespace: 'mimeograph'
    @worker = @conn.worker 'mimeograph', jobs            
    @worker.on 'error',   _.bind @error, @
    @worker.on 'success', _.bind @success, @
    @worker.start()
    log "done spinning up mimeograph"
        
  execute: (@file) ->
    log "processing #{file}"
    redisfs.file2redis @file, deleteFile: false, (err, result) =>
      @key = result.key
      log "recieved #{@key}"
      @conn.enqueue 'mimeograph', 'extract', [@key]

  success: (worker, queue, job, result) ->
    switch job.class 
      when 'extract'      
        if _.isEmpty result then @queue 'split', @key 
        else 
          log.warn "#{@file} does not require OCR."
          redisfs.redis.del @key
          @end()
      when 'split'
        for file in result
          log.warn "Adding convert job for: #{file}"
          @store file, (key) => @queue 'convert', key
      when 'convert'
        @store result, (key) => @queue 'recognize', key
      when 'recognize'
        log "done, recognized #{result.length} chars"

  queue: (job, key) =>
    @conn.enqueue 'mimeograph', job, [key]     

  store: (filename, callback) ->
    redisfs.file2redis filename, (err, result) =>
      if err? then log.err "#{JSON.stringify err}" else callback result.key

  error: (error, worker, queue, job) -> 
    log "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"
    @end()
        
  end: ->
    log "shutting down."
    redisfs.end()
    @worker.end()
    @conn.end()
    process.exit()  

#
#  CLI
#
exports.start = (filename) -> new Mimeograph().execute(filename) 