require 'colors'
_              = require 'underscore'
puts           = console.log
{log, inspect} = require 'util'

exports.log       = (msg) -> log msg.green
exports.log.warn  = (msg) -> log msg.yellow
exports.log.err   = (msg) -> log msg.red

exports.puts       = (obj) -> puts stringify obj
exports.puts.green = (obj) -> puts stringify(obj).green
exports.puts.red   = (obj) -> puts stringify(obj).red
exports.puts.grey  = (obj) -> puts stringify(obj).grey

stringify = (obj) -> if _.isString obj then obj else inspect obj

#
# _ expandos
#
exports._ = _
exports._.isObject      = (val) -> '[object Object]' is toString.apply val
exports._.isEmptyObject = (val) -> _.isObject(val) and _.isEmpty(val)
exports._.now           = -> new Date().toISOString()
exports._.basename      = (file) -> file.substr 0, file.indexOf '.'
exports._.rank          = (file) -> file.substring file.lastIndexOf('-') + 1, file.indexOf '.'
exports._.lpad          = (val, length = 10, char = '0') ->
  val = val.toString().split("")
  val.unshift char while val.length < length
  val.join ''

#
# catch all the junk
#
process.on 'uncaughtException', (err) -> 
  exports.log.err "Caught exception: #{err.stack}"
  process.exit(-1)