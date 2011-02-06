{Accumulator} = require './accumulator'	
{EventEmitter} = require 'events'
{spawn} = require 'child_process'

class PdfTextExtractor extends EventEmitter
	constructor: ->
	extract: (filename) ->			
		proc = spawn "pdftotext" , [filename, "-"]
		proc.stdout.on "data", (data) =>
			@emit "text", data.toString()
		proc.stdout.on "end", () =>
			@emit "done"


exports.Extractor = class Extractor extends EventEmitter
	constructor: (@filename) ->
		@extractor = new PdfTextExtractor()
		@text = new Accumulator()
		@extractor.on "text", (data) =>
			@text.accumulate data
		@extractor.on "done", () =>
			if @text.value? and @text.value.toString().trim() != ""
				@emit "text", @accumulator.value
			else			
				@emit "no-text"
	extract: ->
		@extractor.extract @filename
		
		
