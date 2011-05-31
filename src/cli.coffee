fs             = require 'fs'
coffee         = require 'coffee-script'
{puts}         = require '../src/utils'
mimeograph     = require '../src/mimeograph'
{OptionParser} = require 'coffee-script/lib/optparse'

require.extensions['.coffee'] = (module, filename) ->
   content = coffee.compile fs.readFileSync filename, 'utf8'
   module._compile content, filename

usage = '''
  Usage:
    mimeograph [OPTIONS] [ID] filename
'''

switches = [
  ['-h', '--help', 'Displays options']
  ['-v', '--version', "Shows certain's version."]
  ['-w', '--workers [NUMBER]', 'Number of workers to create. (Default: 5)']
  ['-s', '--start', 'Starts a Mimeograph daemon.']
  ['-p', '--process', 'Kicks of the processing of a new file.']
  ['',   '--port [NUMBER]', "Redis port. (Default: Redis' default)"]
  ['',   '--host [STRING]', "Redis host. (Default: Redis' default)"]
]

argv = process.argv[2..]

@run = ->
  parser = new OptionParser switches, usage
  options = parser.parse argv
  args = options.arguments
  delete options.arguments

  if args.length is 0 and argv.length is 0
    puts parser.help()
    puts "v#{mimeograph.version}"
    process.exit()

  if options.help
    puts parser.help() 
    process.exit()

  if options.version  
    puts "v#{mimeograph.version}"
    process.exit()

  mimeograph.start options.host, options.port, options.workers if options.start
  mimeograph.process args if options.process