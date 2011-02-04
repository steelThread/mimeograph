{spawn} = require 'child_process'
{EventEmitter} = require 'events'

exports.PdfTextExtractor = class PdfTextExtractor extends EventEmitter
	constructor: ->
	extract: (filename) ->			
		proc = spawn "pdftotext" , [filename, "-"]
		proc.stdout.on "data", (data) =>
			@emit "text", data.toString()
		proc.stdout.on "end", () =>
			@emit "done"

		
	