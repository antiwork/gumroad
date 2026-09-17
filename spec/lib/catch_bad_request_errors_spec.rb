# frozen_string_literal: true

require "spec_helper"

describe CatchBadRequestErrors do
  let(:parser) do
    lambda do |env|
      ActionDispatch::Request.new(env).POST
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end
  let(:middleware) { described_class.new(parser) }

  def malformed_request(accept = nil)
    env = Rack::MockRequest.env_for("/", method: "GET", input: "--test", "CONTENT_TYPE" => "multipart/form-data; boundary=test")
    env["HTTP_ACCEPT"] = accept unless accept.nil?
    env
  end

  it "returns HTML 400 for an empty multipart body without Accept" do
    env = malformed_request
    expect(env).not_to have_key("HTTP_ACCEPT")
    expect { parser.call(malformed_request) }.to raise_error(ActionController::BadRequest, /Rack::Multipart::EmptyContentError/)

    expect(middleware.call(env)).to eq([400, { "Content-Type" => "text/html" }, []])
  end

  it "returns 400 through the application middleware stack without Accept" do
    status, _headers, body = Rails.application.call(malformed_request)

    expect(status).to eq(400)
    expect(body.each.to_a.join).to eq("")
  ensure
    body.close if body.respond_to?(:close)
  end

  it "preserves the JSON error response" do
    status, headers, body = middleware.call(malformed_request("application/json"))

    expect(status).to eq(400)
    expect(headers).to eq("Content-Type" => "application/json")
    expect(JSON.parse(body.join)).to eq("success" => false)
  end

  it "returns HTML 400 for an empty Accept header" do
    expect(middleware.call(malformed_request(""))).to eq([400, { "Content-Type" => "text/html" }, []])
  end

  it "leaves valid requests without Accept unchanged" do
    expect(middleware.call(Rack::MockRequest.env_for("/"))).to eq([200, { "Content-Type" => "text/plain" }, ["ok"]])
  end

  it "does not swallow unrelated exceptions" do
    app = described_class.new(->(_env) { raise RuntimeError, "unrelated" })

    expect { app.call({}) }.to raise_error(RuntimeError, "unrelated")
  end
end
