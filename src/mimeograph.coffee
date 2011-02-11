{EventEmitter} = require 'events'
resque         = require 'coffee-resque'
{RedisFS}      = require './redisfs'
temp           = require 'temp'
_              = require 'underscore'
{Accumulator}  = require './accumulator'	
{spawn}        = require 'child_process'
fs             = require 'fs'


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
				@callback null, @text.value.toString().trim()
		
class Splitter
	constructor: (@id, @callback) ->
		@redisfs = new RedisFS()
	split: () ->
		console.log "mimeograph (Splitter): split " + @id
		@redisfs.readFileToTemp @id, (file) =>
			# gs -SDEVICE=jpeg -r300x300 -sPAPERSIZE=letter -sOutputFile=pdf_%04d.jpg -dNOPAUSE -- filename
			console.log "mimeograph (Splitter): splitting file: " + file
			proc = spawn "gs" , ["-SDEVICE=jpeg", "-r300x300", "-sPAPERSIZE=letter", "-sOutputFile="+file+"_%04d.jpg" , "-dNOPAUSE", "--", file]
			proc.stdout.on "end", () =>
				console.log "mimeograph (Splitter): done."
				@redisfs.end()			
				fs.readdir "/tmp", (err, files) =>
					@isSplitImage file, "/tmp/" + candidate for candidate in files
					
	isSplitImage: (basename, filename) ->
		#console.log "mimeograph (Splitter): seeking basename " + basename + " in " + filename
		if filename.toString().match("^" + basename + "?.*jpg?$")
			console.log "mimeograph (Splitter): found matching file: " + filename
			@callback null, filename.toString().trim()
		
class Converter 
	constructor: (@filename, @callback) ->
	convert: () ->
		console.log "mimeograph (Converter): convert " + @filename	
		proc = spawn "convert", ["-quiet", @filename, @filename + ".tif"]
		proc.on "exit", () =>
			@callback null, @filename + ".tif"	
	
class Recognizer
	constructor: (@filename, @callback) ->
	recognize: () ->
		console.log "mimeograph (Recognizer): recognize " + @filename
		proc = spawn "tesseract", [@filename, @filename]
		proc.on "exit", () =>			
			fs.readFile @filename + ".txt", (err, data) =>
				console.log "tesseract data for " + filename + " : " + data
				@callback null, data

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: () ->
		console.log "mimeograph: spinning up mimeograph"
		@conn = resque.connect namespace: 'mimeograph'
		@worker = @conn.worker 'mimeograph', 			
		  extract: (filename, callback) -> new Extractor(filename, callback).extract()
		  split: (filename, callback) -> new Splitter(filename, callback).split()
		  convert: (filename, callback) -> new Converter(filename, callback).convert()
		  recognize: (filename, callback)  -> new Recognizer(filename, callback).recognize()
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
			@store result, @queueConvert 
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
		

		

