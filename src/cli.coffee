{log}        = require './util'
{Mimeograph} = require './mimeograph'

filename = process.argv[2]
log "executing mimeograph for #{filename}"

mimeograph = new Mimeograph()
mimeograph.on "done", (data) ->
  log "mimeograph done.  data: #{data}"
	
mimeograph.execute filename

