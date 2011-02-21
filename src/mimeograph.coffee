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
    log "mimeograph (Extractor): extract #{@key}"
    redisfs.redis2file @key, {deleteFile: false}, (err, file) =>
      if err? then @callback err
      else
        log "mimeograph (Extractor): extract file #{file}"
        proc = spawn "pdftotext" , [file, "-"]
        proc.stdout.on "data", (data) =>
          @text.accumulate data
          proc.stdout.on "end", =>
            @callback null, @text.value.toString().trim()
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
  split: ->
    log "mimeograph (Splitter): split #{@key}"
    redisfs.redis2file @key, (err, file) =>
      if err? then @callback err
      else
        # gs -SDEVICE=jpeg -r300x300 -sPAPERSIZE=letter -sOutputFile=pdf_%04d.jpg -dNOPAUSE -- filename
        log "mimeograph (Splitter): splitting file: #{file}"
        proc = spawn "gs" , ["-SDEVICE=jpeg", "-r300x300", "-sPAPERSIZE=letter", "-sOutputFile=#{file}_%04d.jpg" , "-dNOPAUSE", "--", file]
        proc.stdout.on "end", =>
          log "mimeograph (Splitter): done."
          fs.readdir "/tmp", (err, files) =>
            @isSplitImage file, "/tmp/#{candidate}" for candidate in files
                    
  isSplitImage: (basename, filename) ->
    if filename.match "^#{basename}?.*jpg?$"
      log "mimeograph (Splitter): found matching file: #{filename}"
      @callback null, filename.trim()
        
#
# Convert the file to a tif and pump back into redis.
#
class Converter extends Job
  convert: ->
    log "mimeograph (Converter): convert #{@key}"
    redisfs.redis2file @key, (err, file) =>
      if err? then @callback err
      else
        spawn("convert", ["-quiet", file, "#{file}.tif"]).on 'exit', =>
          @callback null, "#{file}.tif"   

#
# Convert to a txt file.
#   
class Recognizer extends Job
  recognize: ->
    log "mimeograph (Recognizer): recognize #{@key}"
    redisfs.redis2file @key, {suffix:'.tif'}, (err, file) =>
      if err? then @callback err
      else
        spawn("tesseract", [file, file]).on 'exit', =>            
          fs.readFile "#{file}.txt", (err, data) =>
          log "tesseract data for #{file}:#{data}"
          @callback null, data

#
# The resque job callbacks
#
jobs = 
  extract: (filename, callback) -> new Extractor(filename, callback).extract() 
  split: (filename, callback) -> new Splitter(filename, callback).split()
  convert: (filename, callback) -> new Converter(filename, callback).convert()
  recognize: (filename, callback)  -> new Recognizer(filename, callback).recognize()

#
# Manages the process.
#
# Worker model needs to be overhauled.  We should talk about this more.
#
class Mimeograph extends EventEmitter
  constructor: ->
    log "mimeograph: spinning up mimeograph"
    @conn = resque.connect namespace: 'mimeograph'
    @worker = @conn.worker 'mimeograph', jobs            
    @worker.on 'error',   _.bind @error, @
    @worker.on 'success', _.bind @success, @
    #@worker.start()
    log "mimeograph: done spinning up mimeograph"
        
  execute: (file) ->
    log "mimeograph: execute #{file}"
    redisfs.file2redis @file, (err, result) =>
      @key = result.key
      log "mimeograph: recieved #{@key}"
      @conn.enqueue 'mimeograph', 'extract', [@key]

  success: (worker, queue, job, result) ->
    switch job.class 
      when 'extract'      
        if _.isEmpty result then @queue 'split', @key else @end()
      when 'split'
        @store result, (key) => @queue 'convert', key
      when 'convert'
        @store result, (key) => @queue 'recognize', key
      when 'recognize'
        log "mimeograph: done, recognized #{result.length} chars"

  queue: (job, key) =>
    @conn.enqueue 'mimeograph', job, [key]     

  store: (filename, callback) ->
    redisfs.file2redis filename, (err, result) =>
      if err? then log.err "#{JSON.stringify err}" else callback result.key

  error: (error, worker, queue, job) -> 
    log "mimeograph: Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"
    @end()
        
  end: ->
    log "mimeograph: end."
    redisfs.end()
    @emit 'done', result
    process.exit()  

exports.start = (filename) -> 
  try 
    fs.fstatSync filename
    new Mimeograph().execute(filename) 
  catch error
    puts.red "No such file '#{filename}'!"
    process.exit -1