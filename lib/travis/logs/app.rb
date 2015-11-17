require 'json'
require 'raven'
require 'sinatra/base'
require 'logger'
require 'pusher'

require 'travis/logs'
require 'travis/logs/existence'
require 'rack/ssl'

module Travis
  module Logs
    class SentryMiddleware < Sinatra::Base
      configure do
        Raven.configure { |c| c.tags = { environment: environment } }
        use Raven::Rack
      end
    end

    class App < Sinatra::Base
      attr_reader :existence, :pusher, :database

      configure(:production, :staging) do
        use Rack::SSL
      end

      configure do
        use SentryMiddleware if ENV["SENTRY_DSN"]
      end

      def initialize(existence = nil, pusher = nil, database = nil)
        super()
        @existence = existence || Travis::Logs::Existence.new
        @pusher    = pusher    || ::Pusher::Client.new(Travis::Logs.config.pusher)
        @database  = database  || Travis::Logs::Helpers::Database.connect
      end

      post '/pusher/existence' do
        webhook = pusher.webhook(request)
        if webhook.valid?
          webhook.events.each do |event|
            case event["name"]
            when 'channel_occupied'
              existence.occupied!(event['channel'])
            when 'channel_vacated'
              existence.vacant!(event['channel'])
            end
          end

          status 204
          body nil
        else
          status 401
        end
      end

      get "/uptime" do
        status 204
      end

      post "/logs/:id/clear" do
        if request.env["HTTP_AUTHORIZATION"] != "token #{ENV["AUTH_TOKEN"]}"
          halt 403
	end

	database.clear_log(Integer(params[:id]))
	status 204
      end
    end
  end
end
