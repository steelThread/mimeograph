#
# these are some minor utilities that are useful while performing manual
# integration testing of mimeograph.  It is my hope that it will be shortly
# deprecated in favor of a solid suite of unit tests.
#

testutils = exports

fs                    = require 'fs'
{puts, log, copyFile} = require '../src/utils'
{OptionParser}        = require 'coffee-script/lib/coffee-script/optparse'
mimeograph            = require '../src/mimeograph'
redis                 = require 'redis'
util                  = require 'util'
path                  = require 'path'

usage = '''
  Usage:
    testutils [OPTIONS]
'''

switches = [
  ['-h', '--help', 'Displays options']
  ['-v', '--version', "Shows version."]
  ['-l', '--listen', 'Listen for mimegraph job completion messages.']
  ['-p', '--process [file]', 'Kicks of the processing of a new file.']
  ['-c', '--cleanup', 'Delete all keys from redis']
  ['-r', '--redis [hostcolonport]', 'host:port for redis. can be specified as:
 <host>:<port>, <host> or :<port>. In left unspecified the default host and port
 will be used.']
  ['-q', '--quiet', 'When used in conjunction with -l, this will supress text
 and will not copy the outputpdf returned by mimeograph.']
]

class CleanupRedis
  @cleanup: (redisConfig)->
    client = redisConfig.createClient()
    client.flushdb (err) ->
      return log.err "error flushing redis db: #{err}" if err?
      log "successfully flushed redis db."
      client.quit()

class Listener
  constructor: (redisConfig, @quiet)->
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
        if @quiet
          hash.outputpdf = 'this has been supressed'
        else
          @processOutputPdf hash, message
      else
       log.warn "no outputpdf available for #{message}"

      hash.text = "text suppressed. was #{hash.text.length} char(s) long." if @quiet
      log util.inspect hash

  processOutputPdf: (hash, message) ->
    outputpdf = hash.outputpdf
    hash.outputpdf = "output present and #{outputpdf.length} char(s) long"
    #perhaps we should put this in userhome
    pdfDir = "#{__dirname}/outputpdf"
    pdf = "#{pdfDir}/#{message.replace /:/g, '_'}.pdf"
    path.exists pdfDir, (exists) =>
      if exists # make sure it is a dir and write to it
        fs.stat pdfDir, (err, stats) =>
          return log.err err if err?
          return log.err "#{pdfDir} must be a directory" unless stats.isDirectory()
          @writePdf pdf, outputpdf, message
      else # create the dir & write to it
        fs.mkdir pdfDir, (err) =>
          return log.err if err?
          @writePdf pdf, outputpdf, message

  writePdf: (path, content, message) ->
    fs.writeFile path, content, "base64", (err) =>
      return log.err "error writing file for #{message} to #{path}: #{err}" if err?
      log "wrote contents of #{message} to #{path}"

  unboundEnd: ->
    log.warn "shutting down"
    @psClient.quit()
    @client.quit()

  # using => instead of -> because end is called in callbacks specified in
  # the constructor
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
    copyFile sourceFile, tmpTargetFile, (err) ->
      return log.err err if err?
      log "process: [#{jobId}, #{tmpTargetFile}]"
      mimeograph.process [jobId, tmpTargetFile], redisConfig.host, redisConfig.port

class RedisConfig
  constructor: (configString)->
    configString = '' unless configString?
    semiPosition = configString.indexOf ':'
    if semiPosition == -1 #only host name
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
    new Listener(new RedisConfig(options.redis), options.quiet).listen()

  if options.cleanup
    CleanupRedis.cleanup(new RedisConfig(options.redis))

  if options.process
    KickStart.kickStart options.process, new RedisConfig(options.redis)