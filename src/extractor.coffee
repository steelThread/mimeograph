{PdfTextExtractor} = require './pdftextextractor'
{Accumulator} = require './accumulator'		

exports.Extractor = class Extractor extends EventEmitter
	constructor: (@filename) ->
		@extractor = new PdfTextExtractor()
		@text = new Accumulator()
		extractor.on "text", (data) =>
			@text.accumulate data
		extractor.on "done" =>
			if accumulator.value.toString().trim() = ""
				@emit "no-text"
			else			
				@emit "text" accumulator.value
	extract: ->
		extractor.extract(@filename)
		
		
