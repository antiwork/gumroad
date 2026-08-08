# frozen_string_literal: true

require "open3"

RSpec.describe "config/initializers/secure_headers.rb" do
  def cable_connect_src(env)
    cmd = [
      "config = SecureHeaders::Configuration.instance_variable_get(:@default_config)",
      "puts config.csp[:connect_src].grep(/cable/)"
    ].join(";")
    stdout, stderr, status = Open3.capture3(env.merge("RAILS_ENV" => "development"), "bin/rails", "runner", cmd)

    [stdout.lines.map(&:chomp), stderr, status]
  end

  it "allows the default AnyCable websocket port when no lane is active" do
    lines, stderr, status = cable_connect_src({})

    expect(status).to be_success, stderr
    expect(lines).to include("ws://cable.localhost:8080")
  end

  it "follows ANYCABLE_PORT so nonzero dev-lanes are not blocked by the CSP" do
    lines, stderr, status = cable_connect_src("ANYCABLE_PORT" => "8082")

    expect(status).to be_success, stderr
    expect(lines).to include("ws://cable.localhost:8082")
    expect(lines).not_to include("ws://cable.localhost:8080")
  end
end
