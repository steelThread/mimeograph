temp = require 'temp'
{EventEmitter} = require 'events'
fs = require 'fs'
path = require 'path'
{Extractor} = require './extractor'
{Recognizer} = require './recognizer'
resque = require 'coffee-resque'
uuid = require 'node-uuid'
{VFS} = require './vfs'

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: (@filename) ->
		console.log "mimeograph spinning up for " + @filename
		@conn = resque.connect namespace: 'mimeograph'
		@redis = @conn.redis
		@worker = @conn.worker 'recognize', 
		  extract: (filename, callback) -> new Extractor(filename, callback).convert()
		  recognize: (filename, callback)  -> new Recgonizer(filename, callback).recognize()
		@worker.on 'error',   _.bind @error, @
		@worker.on 'success', _.bind @success, @
		@vfs = new VFS("mimeograph")
	execute: (@originalFile) ->
		@vfs.push(@originalFile)
   	    @conn.enqueue 'mimeograph', 'extract', [@originalFile]

		@extractor = new Extractor(@originalFile)
		@extractor.on "text", (data) =>		
			console.log "text in " + @originalFile
			@emit "done", data            		
		@extractor.on "no-text", () =>
			console.log "no text in " + @originalFile
			@recognizer = new Recognizer(@originalFile)
			@recognizer.on "done", (data) =>
				console.log "recognizer done.  emitting signal"
				@emit "done", data
			@recognizer.recognize()
		@extractor.extract()                         
	

