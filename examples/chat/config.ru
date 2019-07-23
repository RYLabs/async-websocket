#!/usr/bin/env -S falcon serve --bind http://localhost:8080 --count 1 -c

require_relative '../../lib/async/websocket/server'
require 'async/clock'
require 'async/semaphore'
require 'async/logger'

require 'set'

class Room
	def initialize
		@connections = Set.new
		@semaphore = Async::Semaphore.new(512)
	end
	
	def connect connection
		@connections << connection
	end
	
	def disconnect connection
		@connections.delete(connection)
	end
	
	def each(&block)
		@connections.each(&block)
	end
	
	def allocations
		counts = Hash.new{|h,k| h[k] = 0}
		
		ObjectSpace.each_object do |object|
			counts[object.class] += 1
		end
		
		return counts
	end
	
	def show_allocations(key, limit = 1000)
		Async.logger.info(self) do |buffer|
			ObjectSpace.each_object(key).each do |object|
				buffer.puts object
			end
		end
	end
	
	def print_allocations(minimum = @connections.count)
		count = 0
		
		Async.logger.info(self) do |buffer|
			allocations.select{|k,v| v >= minimum}.sort_by{|k,v| -v}.each do |key, value|
				count += value
				buffer.puts "#{key}: #{value} allocations"
			end
			
			buffer.puts "** #{count.to_f / @connections.count} objects per connection."
		end
	end
	
	def command(code)
		Async.logger.warn self, "eval(#{code})"
		
		eval(code)
	end
	
	def broadcast(message)
		Async.logger.info "Broadcast: #{message.inspect}"
		start_time = Async::Clock.now
		
		@connections.each do |connection|
			@semaphore.async do
				connection.send_message(message)
			end
		end
		
		end_time = Async::Clock.now
		Async.logger.info "Duration: #{(end_time - start_time).round(3)}s for #{@connections.count} connected clients."
	end
	
	def call(env)
		Async::WebSocket::Server.open(env) do |connection|
			begin
				self.connect(connection)
				
				while message = connection.next_message
					puts "Message: #{message.inspect}"
					if message["text"] =~ /^\/(.*?)$/
						begin
							result = self.command($1)
							
							if result.is_a? Hash
								connection.send_message(result)
							else
								connection.send_message({result: result.inspect})
							end
						rescue
							connection.send_message({error: $!.inspect})
						end
					else
						self.broadcast(message)
					end
				end
			ensure
				self.disconnect(connection)
			end
		end
	end
end

run Room.new
