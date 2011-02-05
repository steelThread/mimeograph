{Mimeograph} = require './mimeograph'

filename = process.argv[2]

mimeograph = new Mimeograph()
mimeograph.on "done", (data) ->
	console.log "mimeograph done.  data: " +data
	
console.log "executing mimeograph for " + filename
mimeograph.execute filename

