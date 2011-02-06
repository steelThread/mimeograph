{Db} = require 'mongodb'
{Connection} = require 'mongodb'
{Server} = require 'mongodb'
{BSONNative} = require 'mongodb'
{GridStore} = require 'mongodb'
UUID = require 'node-uuid'

var host = process.env['MONGO_NODE_DRIVER_HOST'] != null ? process.env['MONGO_NODE_DRIVER_HOST'] : 'localhost';
var port = process.env['MONGO_NODE_DRIVER_PORT'] != null ? process.env['MONGO_NODE_DRIVER_PORT'] : Connection.DEFAULT_PORT;

exports.VFS = class VFS 
	constructor: (@realm) ->
		db1 = new Db realm, new Server host, port, {}, {native_parser:true}
		db1.open(function(err, db) {
	push: (filename, callback) ->
		gridStore = new GridStore db, handle, "w"
		gridStore.open (err, gridStore) =>    
			gridStore.writeFile filename, (err, gridStore) =>
				gridStore.close callback (err, result)
	pop: (handle, callback) ->
		GridStore.read db, filename, callback err, data
				
		
	
		      

