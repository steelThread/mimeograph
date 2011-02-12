redis = require 'redis'
fs    = require 'fs'
UUID  = require 'node-uuid'
temp  = require 'temp'
			
exports.RedisFS = class RedisFS 
	constructor: ->
		@client = redis.createClient()
		@client.on "error", (err) ->
    		console.log "RedisFS: Error " + err
    		
	write: (data, callback) ->
		uuid = UUID()
		console.log "RedisFS: write " + uuid
		@client.set uuid, data, (err, reply) =>
			if err?
				console.log "RedisFS: write error: " + err
			else
				callback uuid, reply
   
	writeFile: (filename, callback) ->
		console.log "RedisFS: writeFile " + filename
		fs.readFile filename, encoding='base64', (err, data) =>
			@write data, callback
			
	read: (uuid, callback) ->
		console.log "RedisFS: read " + uuid
		@client.get uuid, (err, reply) =>
			if err?
				console.log "RedisFS: read error: " + err
			else
				callback reply
				
	readFile: (uuid, outfile, callback) ->
		console.log "RedisFS: readFile " + uuid + " , " + outfile
		@read uuid, (reply) =>
			fs.writeFile outfile, reply, encoding='base64', (err) =>
				if err?
					console.log "RedisFS: fs write error: " + err
				else
					console.log "RedisFS: " + outfile + " written"
					callback outfile
					
	readFileToTemp: (uuid, callback) =>
		console.log "RedisFS: readFileToTemp " + uuid 
		temp.open 'mimeograph', (err, file) =>
			console.log "RedisFS: temp file " + file.path
			@readFile uuid, file.path, callback

	readFileToTempWithHints: (prefix, suffix, uuid, callback) =>	
		console.log "RedisFS: readFileToTemp " + uuid 
		temp.open {'prefix':prefix, 'suffix':suffix}, (err, file) =>
			console.log "RedisFS: temp file " + file.path
			@readFile uuid, file.path, callback
					
	end: () ->
		@client.end()
				
