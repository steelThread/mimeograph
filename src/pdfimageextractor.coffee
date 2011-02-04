{spawn} = require 'child_process'
{EventEmitter} = require 'events'

exports.PdfImageExtractor = class PdfImageExtractor extends EventEmitter
	constructor: ->
	extract: (filename) ->
		# gs -SDEVICE=jpeg -r300x300 -sPAPERSIZE=letter -sOutputFile=pdf_%04d.jpg -dNOPAUSE -- filename
		proc = spawn "gs" , ["-SDEVICE=jpeg", "-r300x300", "-sPAPERSIZE=letter", "-sOutputFile="+filename+"_%04d.jpg" , "-dNOPAUSE", "--", filename]
		proc.stdout.on "end", () =>
			@emit "done"
		
