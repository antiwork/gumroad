# typed: strict
# frozen_string_literal: true

extend Rake::DSL

desc "Notifying Bugsnag about a release"
namespace :bugsnag do
  task deployments: :environment do
    response = HTTParty.post("https://build.bugsnag.com/",
                             headers: { content_type: "application/json" },
                             body: { "apiKey": GlobalConfig.get("BUGSNAG_API_KEY"),
                                     "appVersion": ENV.fetch("REVISION"),
                                     "sourceControl": {
                                       "repository": "git@github.com:gumroad/web.git",
                                       "revision": ENV.fetch("REVISION")
                                     },
                                     "releaseStage": ENV.fetch("RAILS_ENV") }).parsed_response

    puts response
  end
end
