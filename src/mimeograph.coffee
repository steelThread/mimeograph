temp = require 'temp'
{EventEmitter} = require 'events'
fs = require 'fs'
path = require 'path'
{Extractor} = require './extractor'
{Recognizer} = require './recognizer'

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: () ->
	execute: (@originalFile) ->
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
	

