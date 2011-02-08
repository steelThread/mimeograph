redis = require 'redis'
fs = require 'fs'
UUID = require 'uuid'
			
exports.RedisFS = class RedisFS 
	constructor: ->
		@client = redis.createClient()
		@client.on "error", (err) ->
    		console.log "Error " + err
    write: (data, callback) ->
		uuid = UUID()
		@client.set uuid, data, (err, reply) ->
			if err?
				console.log "write error: " + err
			else
				callback uuid, reply
    
	writeFile: (filename, callback) ->
		fs.readFile filename, encoding='base64', (err, data) ->
			write data, callback
			
	read: (uuid, callback) ->
		client.get uuid, (err, reply) ->
			if err?
				console.log "read error: " + err
			else
				callback reply
				
	readFile: (uuid, outfile, callback) ->
		read uuid, (reply) ->
			fs.writeFile outfile, reply, encoding='base64', (err) ->
				if err?
					console.log "fs write error: " + err
				else
					console.log outfile + " written"
					callback()
					
	end: () ->
		@client.end()
				
