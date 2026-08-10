# frozen_string_literal: true

require "open3"

RSpec.describe "config/domain.rb" do
  RUNNER_CMD = <<~'RUBY'
    names = %w[DOMAIN ROOT_DOMAIN ASSET_DOMAIN SHORT_DOMAIN API_DOMAIN DISCOVER_DOMAIN VALID_DISCOVER_REQUEST_HOST]
    names.each { |name| puts "#{name}=#{Object.const_get(name)}" }
    puts "MAILER_HOST=#{Rails.application.config.action_mailer.default_url_options[:host]}"
  RUBY

  def development_domain_constants(env)
    # DISABLE_SPRING: a warm spring server preloads config/domain.rb once, so the
    # per-example env below would never reach it. DEV_LANE_PORT is explicitly
    # nil'd in the no-lane example so a lane shell can't leak it in.
    stdout, stderr, status = Open3.capture3(
      env.merge("RAILS_ENV" => "development", "DISABLE_SPRING" => "1"),
      "bin/rails", "runner", RUNNER_CMD
    )

    # The development boot logs Mongo driver chatter to stdout; keep only the
    # KEY=VALUE lines the runner command prints.
    constants = stdout.lines.filter_map do |line|
      line.chomp.split("=", 2) if line.match?(/\A[A-Z_]+=/)
    end.to_h

    [constants, stderr, status]
  end

  it "pins every domain constant to port 3000 when no lane is active" do
    constants, stderr, status = development_domain_constants({ "DEV_LANE_PORT" => nil })

    expect(status).to be_success, stderr
    expect(constants).to eq(
      "DOMAIN" => "localhost:3000",
      "ROOT_DOMAIN" => "localhost:3000",
      "ASSET_DOMAIN" => "app.localhost:3000",
      "SHORT_DOMAIN" => "s.localhost:3000",
      "API_DOMAIN" => "api.localhost:3000",
      "DISCOVER_DOMAIN" => "localhost:3000",
      "VALID_DISCOVER_REQUEST_HOST" => "localhost",
      "MAILER_HOST" => "localhost:3000"
    )
  end

  it "follows DEV_LANE_PORT so absolute URLs generated inside a dev-lane stay in-lane" do
    constants, stderr, status = development_domain_constants({ "DEV_LANE_PORT" => "3001" })

    expect(status).to be_success, stderr
    expect(constants).to eq(
      "DOMAIN" => "localhost:3001",
      "ROOT_DOMAIN" => "localhost:3001",
      "ASSET_DOMAIN" => "app.localhost:3001",
      "SHORT_DOMAIN" => "s.localhost:3001",
      "API_DOMAIN" => "api.localhost:3001",
      "DISCOVER_DOMAIN" => "localhost:3001",
      # Stays port-less: DiscoverDomainConstraint compares it against
      # request.host, which never carries a port.
      "VALID_DISCOVER_REQUEST_HOST" => "localhost",
      "MAILER_HOST" => "localhost:3001"
    )
  end
end
