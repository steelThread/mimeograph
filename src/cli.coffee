{Mimeograph} = require './mimeograph'

filename = process.argv[2]

mimeograph = new Mimeograph()
mimeograph.on "done", (data) ->
	console.log data
	
mimeograph.execute filename

