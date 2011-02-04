

exports.Accumulator = class Accumulator
	constructor: ->
	accumulate: (data) ->
		if data? 
			if @value? 
				@value += data
			else
				@value = data	
				
