
temp = require 'temp'
{EventEmitter} = require 'events'
fs = require 'fs'
path = require 'path'
{Extractor} = require './extractor'

exports.Mimeograph = class Mimeograph extends EventEmitter
    constructor: @originalFile ->
    	# make a temp dir
        temp.mkdir "mimeograph_" + @originalFile, (err, dirPath) =>
            # copy original file to temp dir
            @sourcePdf = path.join dirPath, 'source.pdf'
            fullOriginalFilePath = fs.realpathSync @originalFile 
            fs.writeFile sourcePdf, fullOriginalFilePath, (err) =>
            	#run extractor to test if there is data
            	extractor = new Extractor(@sourcePdf)
            	
            	extractor.on "text", (data) =>
            		@emit "done", data
            		
            	extractor.on "no-text", () =>
            		recognizer = new Recognizer(@sourcePdf)
            		recognizer.on "done", (data) =>
            			@emit "done", data
            		recognizer.recognize()

            	extractor.extract()                         
	

