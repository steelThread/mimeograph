{spawn} = require 'child_process'
{EventEmitter} = require 'events'
{PdfImageExtractor} = require './pdfimageextractor'
{Accumulator} = require './accumulator'	
fs = require 'fs'
path = require 'path'
temp = require 'temp'
util = require 'util'

class Tesseract extends EventEmitter
	constructor () ->
	convert: (filename) ->
		#tesseract ${t}.tif ${x}
		proc = spawn "tesseract", [filename, filename]
		proc.on "exit", () =>			
			fs.readFile filename + ".txt", (err, data) =>
				console.log "tesseract data for " + filename + " : " + data
				@emit "done", data

class OcrImagePrepConverter extends EventEmitter
	constructor () ->
	convert: (filename, callback) ->
		#convert -quiet  filename filename.tif
		proc = spawn "convert", ["-quiet", filename, filename + ".tif"]
		proc.on "exit", () =>
			callback filename + ".tif"
			
			
exports.Recognizer = class Recognizer extends EventEmitter 
	constructor: (@filename) ->		
		console.log "recognizer spinning up for " + @filename
		@converter = new OcrImagePrepConverter()
		@tesseract = new Tesseract()		
		@text = new Accumulator()
				
		@tesseract.on "done", (data) =>
			@text.accumulate data
			
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
		console.log "candidate file: " + candidate
		if /jpg$/.test candidate
			@converter.convert candidate, (tiffFile) =>
				console.log "tesseracting " + tiffFile
				@tesseract.convert tiffFile
		
			
												
			
