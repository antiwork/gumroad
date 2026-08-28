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

  describe "PROTOCOL" do
    # bin/vite requires config/domain.rb before Rails boots, so these load it the same way:
    # bundler plus vite_ruby and nothing else. A `bin/rails runner` would pull in ActiveSupport
    # and hide the constraint the examples below exist to protect.
    PRE_RAILS_CMD = <<~'RUBY'
      require "bundler/setup"
      require "vite_ruby"
      require File.expand_path("config/domain")
      puts "PROTOCOL=#{PROTOCOL}"
    RUBY

    def pre_rails_protocol(env = {})
      stdout, stderr, status = Open3.capture3(
        env, "ruby", "-e", PRE_RAILS_CMD, chdir: Rails.root.to_s
      )
      [stdout[/^PROTOCOL=(.*)$/, 1], stderr, status]
    end

    it "falls back to the environment default when CUSTOM_PROTOCOL is unset" do
      protocol, stderr, status = pre_rails_protocol("CUSTOM_PROTOCOL" => nil)

      expect(status).to be_success, stderr
      expect(protocol).to eq("http")
    end

    it "falls back to the environment default when CUSTOM_PROTOCOL is blank" do
      # An empty string is truthy in Ruby, so a plain `||` would assign "" here and every
      # absolute URL would come out as "://gumroad.dev".
      protocol, stderr, status = pre_rails_protocol("CUSTOM_PROTOCOL" => "")

      expect(status).to be_success, stderr
      expect(protocol).to eq("http")
    end

    it "uses CUSTOM_PROTOCOL when it is set, so a local backend can serve the app over HTTPS" do
      protocol, stderr, status = pre_rails_protocol("CUSTOM_PROTOCOL" => "https")

      expect(status).to be_success, stderr
      expect(protocol).to eq("https")
    end

    it "loads before Rails even with CUSTOM_DOMAIN set, without ActiveSupport predicates" do
      # `present?`/`presence` raise NoMethodError in this path. CUSTOM_DOMAIN is what reaches the
      # branch that used to call one, and it is exactly the setup CUSTOM_PROTOCOL pairs with.
      protocol, stderr, status = pre_rails_protocol(
        "CUSTOM_DOMAIN" => "gumroad.dev", "CUSTOM_PROTOCOL" => "https"
      )

      expect(status).to be_success, stderr
      expect(protocol).to eq("https")
    end
  end
end
