{EventEmitter} = require 'events'
resque         = require 'coffee-resque'
{RedisFS}      = require './redisfs'
temp           = require 'temp'
_              = require 'underscore'
{Accumulator}  = require './accumulator'	
{spawn}        = require 'child_process'


_.isObject = (val) -> '[object Object]' is toString.apply val

class Extractor
	constructor: (@id, @callback) ->
		@redisfs = new RedisFS()
		@text = new Accumulator()
	extract: () ->
		console.log "mimeograph (Extractor): extract " + @id
		@redisfs.readFileToTemp @id, (file) =>
			console.log "mimeograph (Extractor): extract file " + file
			@redisfs.end()
			proc = spawn "pdftotext" , [file, "-"]
			proc.stdout.on "data", (data) =>
				@text.accumulate data
			proc.stdout.on "end", () =>
				@callback null, @text.value.trim()
		
class Splitter
	constructor: (@filename) ->
	split: (callback) ->
		console.log "mimeograph (Splitter): split " + @filename
		callback null, ["foo.jpg", "bar.jpg", "baz.jgp"]
		
class Converter 
	constructor: (@filename) ->
	convert: (callback) ->
		console.log "mimeograph (Converter): convert " + @filename	
		callback null, "foo.tif"
	
class Recognizer
	constructor: (@filename) ->
	recognize: (callback) ->
		console.log "mimeograph (Recognizer): recognize " + @filename
		callback null, "foo"

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: () ->
		console.log "mimeograph: spinning up mimeograph"
		@conn = resque.connect namespace: 'mimeograph'
		@worker = @conn.worker 'mimeograph', 			
		  extract: (filename, callback) -> new Extractor(filename, callback).extract()
		  #split: (filename, callback) -> new Splitter(filename, callback).split()
		  #convert: (filename, callback) -> new Converter(filename).convert(callback)
		  #recognize: (filename, callback)  -> new Recgonizer(filename).recognize(callback)
		@worker.on 'error',   _.bind @error, @
		@worker.on 'success', _.bind @success, @
		@redisfs = new RedisFS()
		@worker.start()
		console.log "mimeograph: done spinning up mimeograph"
		
	execute: (@originalFile) ->
		console.log "mimeograph: execute " + @originalFile
		@redisfs.writeFile @originalFile, (uuid, reply) =>
			@id = uuid			
			console.log "mimeograph: recieved " + @id
			@conn.enqueue 'mimeograph', 'extract', [@id]

	success: (worker, queue, job, result) -> 
		if job.class is 'extract'		
			if _.isEmpty result  
				@conn.enqueue 'mimeograph', 'split', [@id]
			else 
				@emit 'done', result
				@end()
		else if job.class is 'split'
			@store filename, queueconvert for filename in result
		else if job.class is 'convert'
			@store result, (uuid, reply) =>
				@conn.enqueue 'mimeograph', 'recognize', [uuid]
		else if job.class is 'recognize'
			@emit 'done', result

	queueConvert: (uuid, reply) =>
		@conn.enqueue 'mimeograph', 'convert', [uuid]

	store: (filename, callback) ->
		@redisfs.writeFile filename, callback

	error: (error, worker, queue, job) -> 
		console.log "mimeograph: Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"
		@end()
		
	end: () ->
		console.log "mimeograph: end."
		@redisfs.end()
		process.exit()
		

		

