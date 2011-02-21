#
# Beyond simple accumulator
#
class Accumulator
  constructor: (@value = '') ->
  accumulate: (data) ->
    @value += data if data?

exports.Accumulator = Accumulator    
				
