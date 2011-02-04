{spawn} = require 'child_process'
{EventEmitter} = require 'events'
{PdfImageExtractor} = require './pdfimageextractor'
{Accumulator} = require './accumulator'	
fs = require 'fs'
path = require 'path'
temp = require 'temp'

class Tesseract extends EventEmitter
	constructor () ->
	convert: (filename) ->
		#tesseract ${t}.tif ${x}
		proc = spawn "tesseract", [filename, filename]
		proc.on "exit", () =>			
			fs.readFile filename + ".txt", (err, data) =>
				if err
					throw err;
				@emit "done", data

class OcrImagePrepConverter extends EventEmitter
	constructor () ->
	convert: (filename) ->
		#convert -quiet  filename filename.tif
		proc = spawn "convert", ["-quiet", filename, filename + ".tif"]
		proc.on "exit", () =>
			@emit "done", filename + ".tif"
			
			
exports.Recognizer = class Recognizer extends EventEmitter 
	constructor: (@filename) ->		
		@converter = new OcrImagePrepConverter()
		@tesseract = new Tesseract()		
		@text = new Accumulator()
				
		@tesseract.on "done", (data) =>
			@text.accumulate data
			
	recognize: ->
		temp.mkdir "mimeograph_" + @filename, (err, dirPath) =>
            process.chdir(dirPath);

            # copy original file to temp dir
            @sourcePdf = path.join dirPath, 'source.pdf'
            fullOriginalFilePath = fs.realpathSync @filename
            fs.writeFile @sourcePdf, fullOriginalFilePath, (err) =>   
				imageExtractor = new PdfImageExtractor()	         	
				imageExtractor.on "done", () =>
					fs.readdir dirpath, (err, files) =>	
						executeOcrOnImages file for file in files						
					@emit "done", @text.value					
				imageExtractor.extract(@sourcePdf)
	executeOcrOnImages: (candidate) ->
		if /jpg$/.test candidate
			@converter.convert(imageFile)
			@converter.on "done", (tiffFile) =>
				@tesseract.convert(tiffFile)				
												
			
