#!/usr/bin/env coffee

fs             = require 'fs'
coffee         = require 'coffee-script'
{puts}         = require '../src/utils'
mimeograph        = require '../src/mimeograph'
{OptionParser} = require 'coffee-script/optparse'

require.extensions['.coffee'] = (module, filename) ->
   content = coffee.compile fs.readFileSync filename, 'utf8'
   module._compile content, filename

usage = '''
  Usage:
    mimeograph [OPTIONS] filename
'''

switches = [
  ['-h', '--help', 'Displays options']
  ['-v', '--version', "Shows certain's version."]
  ['-w', '--workers [NUMBER]', 'Number of workers to create. Ex.: 5 (default)']
  ['start', '--start', 'Starts a Mimeograph daemon.']
  ['request', '--request', 'Kicks of the processing of a new file.']
]

argv = process.argv[2..]
parser = new OptionParser switches, usage
options = parser.parse argv
args = options.arguments
delete options.arguments

if args.length is 0 and argv.length is 0
  puts parser.help()
  puts "v#{mimeograph.version}"

puts parser.help() if options.help
puts "v#{mimeograph.version}" if options.version
mimeograph.start() if options.start
mimeograph.request args[1] if options.request
  
