{log} = require './utils'
redis = require 'redis'  

listener = redis.createClient()

listener.on 'pmessage', (pattern, channel, message) ->  log.warn "Received - #{message}"
listener.psubscribe "mimeograph:*"