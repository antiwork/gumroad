# frozen_string_literal: true

require "spec_helper"

describe "Sentry configuration" do
  it "is not enabled in the test environment" do
    expect(Sentry.configuration.enabled_in_current_env?).to eq(false)
  end

  it "only enables production and staging environments" do
    expect(Sentry.configuration.enabled_environments).to eq(%w[production staging])
  end

  describe "before_send" do
    subject(:before_send) { Sentry.configuration.before_send }

    def build_event(tags:, request: nil)
      instance_double(Sentry::ErrorEvent, tags:, request:)
    end

    def build_exception(backtrace)
      StandardError.new("undefined method 'id' for nil").tap { _1.set_backtrace(backtrace) }
    end

    it "drops runner-source events raised from ad-hoc stdin scripts" do
      exception = build_exception([
                                    "stdin:2:in '<main>'",
                                    "/app/bin/rails:8:in '<main>'",
                                  ])
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, exception:)).to be_nil
    end

    it "drops runner-source events even when app code appears below the stdin frame" do
      exception = build_exception([
                                    "/app/app/models/user.rb:10:in 'do_something'",
                                    "stdin:5:in '<main>'",
                                  ])
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, exception:)).to be_nil
    end

    it "keeps runner-source events from file-based scripts (no stdin frame)" do
      exception = build_exception([
                                    "/app/lib/tasks/backfill.rb:12:in 'run'",
                                    "/app/bin/rails:8:in '<main>'",
                                  ])
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, exception:)).to eq(event)
    end

    it "keeps non-runner events even when the backtrace mentions stdin" do
      exception = build_exception(["stdin:1:in '<main>'"])
      event = build_event(tags: {})

      expect(before_send.call(event, exception:)).to eq(event)
    end

    it "keeps events without an exception hint" do
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, {})).to eq(event)
    end

    it "keeps events when the hint itself is nil" do
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, nil)).to eq(event)
    end

    it "keeps events when the exception has no backtrace" do
      event = build_event(tags: { source: "runner" })

      expect(before_send.call(event, exception: StandardError.new("boom"))).to eq(event)
    end
  end

  describe "Gumhead gateway request scrubbing" do
    def build_request(url)
      Sentry::RequestInterface.allocate.tap do |request|
        request.url = url
        request.data = { "messages" => "seller prompt" }
        request.headers = { "Authorization" => "Bearer secret" }
        request.cookies = "session=abc"
        request.query_string = "a=1"
        request.env = { "REMOTE_ADDR" => "1.2.3.4" }
      end
    end

    it "empties the request interface for gateway URLs in before_send" do
      request = build_request("https://api.gumroad.com/v2/gumhead/v1/messages")
      event = instance_double(Sentry::ErrorEvent, tags: {}, request:)

      expect(Sentry.configuration.before_send.call(event, nil)).to eq(event)
      expect(request.data).to be_nil
      expect(request.headers).to eq({})
      expect(request.cookies).to be_nil
      expect(request.query_string).to be_nil
      expect(request.env).to be_nil
    end

    it "empties the request interface for gateway URLs in before_send_transaction" do
      request = build_request("https://gumroad.com/api/v2/gumhead/v1/messages")
      event = instance_double(Sentry::TransactionEvent, request:)

      expect(Sentry.configuration.before_send_transaction.call(event, nil)).to eq(event)
      expect(request.data).to be_nil
      expect(request.headers).to eq({})
    end

    it "leaves other routes' request data untouched" do
      request = build_request("https://gumroad.com/purchases")
      event = instance_double(Sentry::ErrorEvent, tags: {}, request:)

      Sentry.configuration.before_send.call(event, nil)

      expect(request.data).to eq({ "messages" => "seller prompt" })
      expect(request.headers).to eq({ "Authorization" => "Bearer secret" })
    end
  end
end
