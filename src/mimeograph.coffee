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
  extract: ->
    log "(Extractor): extract #{@key}"
    redisfs.redis2file @key, deleteKey: false, (err, file) =>
      return @callback err if err?
      log "(Extractor): extract file #{file}"
      proc = spawn 'pdftotext', [file, '-']
      proc.stdout.on 'data', (data) => @text.accumulate data
      proc.on 'exit', =>
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
  split: ->
    log "Split: #{@key}"
    redisfs.redis2file @key, deleteKey: true, (err, file) =>
      return @callback err if err?
      target = file.substr file.lastIndexOf('/') + 1
      log "(Splitter): splitting file: #{file}"
      proc = spawn 'gs', [
        '-SDEVICE=jpeg' 
        '-r300x300'
        '-sPAPERSIZE=letter'
        "-sOutputFile=/tmp/#{target}_%04d.jpg"
        '-dNOPAUSE'
        '--'
        file
      ]
      proc.stdout.on "end", =>
        fs.readdir "/tmp", (err, files) =>
          @gather target, "#{candidate}" for candidate in files
          @callback @splits
                    
  gather: (basename, filename) ->
    @splits.push "/tmp/#{filename}" if filename.match "^#{basename}?.*jpg?$"
        
#
# Convert the jpg to a tif and pump back into redis.
#
class Converter extends Job
  convert: ->
    log "Convert: #{@key}"
    redisfs.redis2file @key, filename: @key, (err, file) => 
      return @callback err if err?
      target = "#{file.substr 0, file.indexOf '.'}.tif"
      proc = spawn "convert", ["-quiet", file, target]
      proc.on 'exit', => @callback target   

#
# Convert to a txt file.
#   
class Recognizer extends Job
  recognize: ->
    log "Recognize: #{@key}"
    redisfs.redis2file @key, {filename: @key}, (err, file) =>
      return @callback err if err?
      target = file.substr 0, file.indexOf '.'
      proc = spawn "tesseract", [file, target]
      proc.on 'exit', (code) =>
        return callback new Error 'tesseract' if code isnt 0  
        fs.readFile "#{target}.txt", 'utf8', (err, data) =>
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
      @enqueue 'extract', [@key]

  success: (worker, queue, job, result) ->
    switch job.class 
      when 'extract'      
        if _.isEmpty result then @enqueue 'split', @key 
        else 
          log.warn "#{@file} does not require OCR."
          redisfs.redis.del @key
          @end()
      when 'split'
        for file in result
          @store file, (key) => @enqueue 'convert', key
      when 'convert'
        @store result, (key) => @enqueue 'recognize', key
      when 'recognize'
        log "done, recognized #{result.length} chars"

  enqueue: (job, key) =>
    @conn.enqueue 'mimeograph', job, [key]     

  store: (filename, callback) ->
	# use the filename as the key as it will be unique after the split
    redisfs.file2redis filename, key: filename, (err, result) =>
      return log.err "#{JSON.stringify err}" if err?
      callback result.key

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
exports.start = (filename) -> new Mimeograph().execute filename