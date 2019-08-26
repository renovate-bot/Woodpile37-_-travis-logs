# frozen_string_literal: true

require 'concurrent'
require 'date'
require 'travis/logs'

module Travis
  module Logs
    module Services
      class SendTimings
        attr_reader :job_id, :database

        private :database

        TIMER_START = /travis_time:start:(?<timer_id>[0-9a-f]+)/
        TIMER_END = /travis_time:end:(?<timer_id>[0-9a-f]+):(?<info>[^\r]+)\r/

        def self.run
          new.run
        end

        def self.send_timings(job_id)
          new.send_timings(job_id)
        end

        def initialize(job_id, database: Travis::Logs.database_connection)
          @job_id   = job_id
          @database = database
        end

        def run
          send_timings job_id
        end

        def send_timings(job_id)
          timer_stack = []

          content.each_line do |l|
            l.scan(/#{TIMER_START}|#{TIMER_END}/) do |start_timer_id, end_timer_id, info|

              if start_timer_id
                timer_stack << start_timer_id
                next
              end

              if timer_stack.empty?
                next
              end
              unless (last_timer_id = timer_stack.pop) == end_timer_id
                next
              end

              # matched TIMER_END regexp, so we have `end_timer_id` and `info` defined

              marker_data = parse_marker_data(info)

              next unless marker_data.key?(:duration)

              # duration is given by nanoseconds
              duration_ms = marker_data.delete(:duration).to_i / (10**6)

              event = {
                duration_ms: duration_ms,
                job_id: job_id,
                cmd_start_time: DateTime.strptime(start_timer_id[0..-10], '%s'), # drop last 9 digits to create time in seconds
                cmd_end_time:   DateTime.strptime(end_timer_id[0..-10],   '%s'), # drop last 9 digits to create time in seconds
              }.merge(marker_data)

              #Travis::Honeycomb.send(event) # but this is not the right client…
              Travis.logger.info event
            end
          end
        end

        def log
          @log ||= begin
            log = database.log_for_id(job_id)
            unless log
              Travis.logger.warn(
                'log not found',
                action: 'archive', id: job_id, result: 'not_found'
              )
              mark('log.not_found')
            end
            log
          end
        end
        alias fetch log

        private

        def content
          @content ||= log[:content]
        end

        attr_writer :content
        private :content

        def parse_marker_data(str)
          # given a comma-delimited string with each being an equal-delimited
          # key-value paris, build a hash with the key-value pairs thus specified
          # with symbols as keys
          # e.g., 'a=b,c=d' => '{:a=>"b", :c=> "d"}'
          str.split(',').map { |s| s.split('=', 2) }.to_h.transform_keys(&:to_sym)
        end
      end
    end
  end
end
