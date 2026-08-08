# frozen_string_literal: true

require "open3"

RSpec.describe "config/initializers/secure_headers.rb" do
  def development_csp(env, pattern)
    cmd = [
      "config = SecureHeaders::Configuration.instance_variable_get(:@default_config)",
      "puts config.csp[:connect_src].grep(#{pattern.inspect})"
    ].join(";")
    # DISABLE_SPRING: a warm spring server preloads initializers once, so the
    # per-example env below would never reach them.
    stdout, stderr, status = Open3.capture3(
      env.merge("RAILS_ENV" => "development", "DISABLE_SPRING" => "1"),
      "bin/rails", "runner", cmd
    )

    [stdout.lines.map(&:chomp), stderr, status]
  end

  it "allows the default AnyCable and Vite ports when no lane is active" do
    lines, stderr, status = development_csp({}, /cable|3036/)

    expect(status).to be_success, stderr
    expect(lines).to include("ws://cable.localhost:8080")
    expect(lines).to include("ws://localhost:3036")
  end

  it "follows ANYCABLE_PORT and VITE_RUBY_PORT so nonzero dev-lanes are not blocked by the CSP" do
    lines, stderr, status = development_csp(
      { "ANYCABLE_PORT" => "8082", "VITE_RUBY_PORT" => "3040" }, /cable|30\d\d/
    )

    expect(status).to be_success, stderr
    expect(lines).to include("ws://cable.localhost:8082")
    expect(lines).to include("ws://localhost:3040")
    expect(lines).not_to include("ws://cable.localhost:8080")
    expect(lines).not_to include("ws://localhost:3036")
  end
end
