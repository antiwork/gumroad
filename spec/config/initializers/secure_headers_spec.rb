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

  def development_csp_json(env, directives)
    cmd = [
      "config = SecureHeaders::Configuration.instance_variable_get(:@default_config)",
      "puts({ asset_host: Rails.application.config.asset_host, csp: config.csp.to_h.slice(*#{directives.inspect}) }.to_json)"
    ].join(";")
    stdout, stderr, status = Open3.capture3(
      env.merge("RAILS_ENV" => "development", "DISABLE_SPRING" => "1"),
      "bin/rails", "runner", cmd
    )

    [JSON.parse(stdout), stderr, status]
  end

  it "denies plugin documents, foreign base targets, and wildcard worker sources" do
    body, stderr, status = development_csp_json({}, %i[object_src base_uri child_src worker_src])

    expect(status).to be_success, stderr
    csp = body.fetch("csp")
    expect(csp["object_src"]).to eq(["'none'"])
    expect(csp["base_uri"]).to eq(["'self'"])
    expect(csp["child_src"]).to eq(["'self'", "blob:"])
    expect(csp["worker_src"]).to include("'self'", "blob:")
    expect(csp["worker_src"]).not_to include("*", "data:")
    # pdfjs resolves its worker through Vite, so it is served from the CDN asset
    # host in production and would be blocked by a bare "'self'".
    expect(body["asset_host"]).to be_present
    expect(csp["worker_src"]).to include(body["asset_host"])
  end

  it "allows the lane's Vite server as a worker source" do
    body, stderr, status = development_csp_json({ "VITE_RUBY_PORT" => "3040" }, %i[worker_src])

    expect(status).to be_success, stderr
    expect(body.dig("csp", "worker_src")).to include("localhost:3040")
    expect(body.dig("csp", "worker_src")).not_to include("localhost:3036")
  end
end
