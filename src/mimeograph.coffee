
temp = require 'temp'
{EventEmitter} = require 'events'
fs = require 'fs'
path = require 'path'
{Extractor} = require './extractor'
{Recognizer} = require './recognizer'

exports.Mimeograph = class Mimeograph extends EventEmitter
	constructor: (@originalFile) ->
	execute: () ->
		@extractor = new Extractor(@originalFile)
		@extractor.on "text", (data) =>
			@emit "done", data            		
		@extractor.on "no-text", () =>
			@recognizer = new Recognizer(@originalFile)
			@recognizer.on "done", (data) =>
				@emit "done", data
			@recognizer.recognize()
		@extractor.extract()                         
	

