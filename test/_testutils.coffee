#
# these are some minor utilities that are useful while performing manual
# integration testing of mimeograph.  It is my hope that it will be shortly
# deprecated in favor of a solid suite of unit tests.
#

testutils = exports

fs             = require 'fs'
{puts, log}         = require '../src/utils'
{OptionParser} = require 'coffee-script/lib/coffee-script/optparse'
mimeograph     = require '../src/mimeograph'
redis          = require 'redis'
util           = require 'util'

usage = '''
  Usage:
    testutils [OPTIONS]
'''

#TODO ability to specify redis server:port in listen & process switch
switches = [
  ['-h', '--help', 'Displays options']
  ['-v', '--version', "Shows version."]
  ['-l', '--listen', 'Listen for mimegraph job completion messages.']
  ['-p', '--process [file]', 'Kicks of the processing of a new file.']
  ['-c', '--cleanup', 'Delete all keys from redis']
  ['-r', '--redis [hostcolonport]', 'host:port for redis. can be specified as:
 <host>:<port>, <host> or :<port>. In left unspecified the default host and port
 will be used.']
]

class CleanupRedis
  @cleanup: (redisConfig)->
    client = redisConfig.createClient()
    client.flushdb (err) ->
      return log.err "error flushing redis db: #{err}" if err?
      log "successfully flushed redis db."
      client.quit()

class Listener
  constructor: (redisConfig)->
    # access redis
    @psClient = redisConfig.createClient()
    @client = redisConfig.createClient()
    process.on 'SIGINT',  @end
    process.on 'SIGTERM', @end
    process.on 'SIGQUIT', @end

  listen: ->
    @psClient.on "pmessage", (pattern, channel, message) =>
      log "received pmessage for pattern: '#{pattern}' from '#{channel}': '#{message}'."
      @fetchJobInfo channel, message

    @psClient.on "psubscribe", (pattern, count) ->
        log "subscribed to pattern '#{pattern}'. this client has #{count} active subscription(s)."

    @psClient.psubscribe 'mimeograph:job:*'

  fetchJobInfo: (channel, message) ->
    @client.hgetall channel, (err, hash) =>
      return log.err "error retrieving hash #{message}: #{err}" if err?
      if hash.outputpdf? #copy results out
        outputpdf = hash.outputpdf
        hash.outputpdf = "output present and #{outputpdf.length} char(s) long"
        #TODO create outputpdf dir it is doesn't already exist - perhaps we should put this in userhome
        pdf = "#{__dirname}/outputpdf/#{message}.pdf"
        fs.writeFile pdf, outputpdf, "base64", (err) =>
          return log.err "error writing out outputpdf for #{message} to #{pdf}: #{err}" if err?
          log "wrote outputpdf for #{message} to #{pdf}"
      else
       log.warn "no outputpdf available for #{message}"

      log util.inspect hash

  end: =>
    log.warn "shutting down"
    @psClient.quit()
    @client.quit()

class KickStart
  @kickStart: (sourceFile, redisConfig) ->
    log "file to process: #{sourceFile}"
    jobId = new Date().getTime()
    tmpTargetFile = "/tmp/#{jobId}"

    stats = fs.lstatSync sourceFile
    log "size of #{sourceFile}: #{stats.size}"
    @copy sourceFile, tmpTargetFile, () ->
      log "process: [#{jobId}, #{tmpTargetFile}]"
      mimeograph.process [jobId, tmpTargetFile], redisConfig.host, redisConfig.port

  @copy: (sourceFile, targetFile, callback) ->
    log "in copy"
    readStream = fs.createReadStream sourceFile
    writeStream = fs.createWriteStream targetFile
    readStream.on 'end', ->
      log "finished copying #{sourceFile} to #{targetFile}"
      callback()
    readStream.on 'error', (err)->
      log.err "error reading from #{sourceFile}: #{err}"
    writeStream.on 'error', (err)->
      log.err "error writing from #{targetFile}: #{err}"
    readStream.pipe writeStream

class RedisConfig
  constructor: (configString)->
    configString = '' unless configString?
    semiPosition = configString.indexOf ':'
    if semiPosition  == -1 #only host name
      @host = configString
    else if semiPosition == 0 #only port
      @port = configString.substr 1
    else
      @host = configString.substr 0, semiPosition
      @port = configString.substr (semiPosition+1)

  createClient: ->
    redis.createClient @port, @host

testutils.run = ->
  argv = process.argv[2..]
  parser = new OptionParser switches, usage
  options = parser.parse argv
  args = options.arguments
  delete options.arguments

  if args.length is 0 and argv.length is 0
    puts parser.help()
    log "v#{mimeograph.version}"
    process.exit()

  if options.help
    puts parser.help()
    process.exit()

  if options.version
    log "v#{mimeograph.version}"
    process.exit()

  if options.listen
    new Listener(new RedisConfig(options.redis)).listen()

  if options.cleanup
    CleanupRedis.cleanup(new RedisConfig(options.redis))

  if options.process
    KickStart.kickStart options.process, new RedisConfig(options.redis)