{PdfTextExtractor} = require './pdftextextractor'
{Accumulator} = require './accumulator'	
{EventEmitter} = require 'events'

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
		
		
