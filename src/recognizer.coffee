{spawn} = require 'child_process'
{EventEmitter} = require 'events'
{Accumulator} = require './accumulator'	
fs = require 'fs'
path = require 'path'
temp = require 'temp'
util = require 'util'
resque = require 'coffee-resque'

class PdfImageExtractor extends EventEmitter
	constructor: ->
	extract: (filename) ->
		# gs -SDEVICE=jpeg -r300x300 -sPAPERSIZE=letter -sOutputFile=pdf_%04d.jpg -dNOPAUSE -- filename
		console.log "extracting: " + filename
		proc = spawn "gs" , ["-SDEVICE=jpeg", "-r300x300", "-sPAPERSIZE=letter", "-sOutputFile="+filename+"_%04d.jpg" , "-dNOPAUSE", "--", filename]
		proc.stdout.on "end", () =>
			@emit "done"

class Tesseract 
	constructor (@filename, @callback) ->
	recognize: () ->
		#tesseract ${t}.tif ${x}
		proc = spawn "tesseract", [@filename, @filename]
		proc.on "exit", () =>			
			fs.readFile filename + ".txt", (err, data) =>
				console.log "tesseract data for " + filename + " : " + data
				callback data
				

class OcrImagePrepConverter extends EventEmitter
	constructor (@filename, @callback) ->
	convert: () ->
		#convert -quiet  filename filename.tif
		proc = spawn "convert", ["-quiet", @filename, @filename + ".tif"]
		proc.on "exit", () =>
			callback @filename + ".tif"			
			
exports.Recognizer = class Recognizer extends EventEmitter 
	constructor: (@filename) ->
		console.log "recognizer spinning up for " + @filename
		@conn = resque.connect namespace: 'mimeograph'
		@redis = @conn.redis
		@worker = @conn.worker 'recognize', 
		  convert: (filename, callback) -> new OcrImagePrepConverter(filename, callback).convert()
		  tesseract: (filename, callback)  -> new Tesseract(filename, callback).recognize()
		@worker.on 'error',   _.bind @error, @
		@worker.on 'success', _.bind @success, @
		@text = new Accumulator()

	queue: (job, work) -> 
		@conn.enqueue 'recognize', job, [work]

	success: (worker, queue, job, result) -> 
		if job.class is 'recognize'
			@text.accumulate result
		else if job.class is 'convert'
			@queue 'tesseract', result
			@redis.incr @conn.key('processing:page'), (err, pg) => @work()

	error: (error, worker, queue, job) -> 
		console.log "Error processing job #{JSON.stringify job}.  #{JSON.stringify error}"

							
	recognize: ->
		temp.mkdir "mimeograph_", (err, dirPath) =>
			console.log "temp dir path " + dirPath
			process.chdir dirPath
            # copy original file to temp dir
			@sourcePdf = path.join dirPath, 'source.pdf'
			ins = fs.createReadStream @filename
			outs = fs.createWriteStream @sourcePdf
			util.pump ins, outs, () =>
				imageExtractor = new PdfImageExtractor()	         	
				imageExtractor.on "done", () =>
					files = fs.readdirSync dirPath
					@executeOcrOnImages file for file in files						
				imageExtractor.extract(@sourcePdf)	
	executeOcrOnImages: (candidate) ->
		#console.log "candidate file: " + candidate
		if /jpg$/.test candidate
			@converter.convert candidate, (tiffFile) =>
				#console.log "tesseracting " + tiffFile
				@tesseract.convert tiffFile
		
			
												
			
