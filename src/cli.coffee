{Mimeograph} = require './mimeograph'

filename = process.argv[2]
console.log "executing mimeograph for " + filename

mimeograph = new Mimeograph()
mimeograph.on "done", (data) ->
	console.log "mimeograph done.  data: " +data
	
mimeograph.execute filename

