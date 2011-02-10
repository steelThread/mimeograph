{EventEmitter} = require 'events'
resque         = require 'coffee-resque'
{RedisFS}      = require './redisfs'
temp           = require 'temp'
_              = require 'underscore'


_.isObject = (val) -> '[object Object]' is toString.apply val

class Extractor
	constructor: (@id, @callback) ->
		@redisfs = new RedisFS()
	extract: () ->
		console.log "extract " + @id
		@redisfs.readFileToTemp @id, (file) =>
			console.log "extract file " + file
			@callback "intentional", "foo"
		
class Splitter
	constructor: (@filename) ->
	split: (callback) ->
		console.log "split " + @filename
		callback null, ["foo.jpg", "bar.jpg", "baz.jgp"]
		
class Converter 
	constructor: (@filename) ->
	convert: (callback) ->
		console.log "convert " + @filename	
		callback null, "foo.tif"
	
class Recognizer
	constructor: (@filename) ->
	recognize: (callback) ->
		console.log "recognize " + @filename
		callback null, "foo"

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: () ->
		console.log "spinning up mimeograph"
		@conn = resque.connect namespace: 'mimeograph'
		@worker = @conn.worker 'mimeograph', 			
		  extract: (filename, callback) -> new Extractor(filename, callback).extract()
		  #convert: (filename, callback) -> new Converter(filename).convert(callback)
		  #split: (filename, callback) -> new Splitter(filename).split(callback)
		  #recognize: (filename, callback)  -> new Recgonizer(filename).recognize(callback)
		@worker.on 'error',   _.bind @error, @
		@worker.on 'success', _.bind @success, @
		@redisfs = new RedisFS()
		@worker.start()
		console.log "done spinning up mimeograph"
		
	execute: (@originalFile) ->
		console.log "execute " + @originalFile
		@redisfs.writeFile @originalFile, (uuid, reply) =>
			@id = uuid			
			console.log "recieved " + @id
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
		console.log "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"
		@end()
		
	end: () ->
		console.log "mimeograph: end."
		@redisfs.end()
		process.exit()
		

		

