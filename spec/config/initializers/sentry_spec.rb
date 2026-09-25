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

  describe "retired Gumhead gateway requests" do
    # Real events built through the SDK's scope, so the request context is the one a
    # sampled production request would carry.
    def event_for(url, type)
      env = Rack::MockRequest.env_for(
        url,
        method: "POST",
        input: { messages: "seller prompt" }.to_json,
        "CONTENT_TYPE" => "application/json",
        "HTTP_AUTHORIZATION" => "Bearer secret",
      )
      event = if type == :transaction
        Sentry::TransactionEvent.new(configuration: Sentry.configuration, transaction: Sentry::Transaction.new(name: "POST", op: "http.server"))
      else
        Sentry::ErrorEvent.new(configuration: Sentry.configuration)
      end
      scope = Sentry::Scope.new
      scope.set_rack_env(env)
      scope.apply_to_event(event)
      event
    end

    it "drops error events for the retired gateway URLs" do
      event = event_for("https://example.com/v2/gumhead/v1/messages", :error)
      expect(event.request.headers).to include("Authorization" => "Bearer secret")

      expect(Sentry.configuration.before_send.call(event, nil)).to be_nil
    end

    it "drops transactions for the retired gateway URLs" do
      event = event_for("https://example.com/api/v2/gumhead/v1/messages", :transaction)
      expect(event.request.headers).to include("Authorization" => "Bearer secret")
      expect(event.request.data).to include("seller prompt")

      expect(Sentry.configuration.before_send_transaction.call(event, nil)).to be_nil
    end

    it "keeps events for other URLs" do
      error = event_for("https://example.com/purchases", :error)
      transaction = event_for("https://example.com/purchases", :transaction)

      expect(Sentry.configuration.before_send.call(error, nil)).to eq(error)
      expect(Sentry.configuration.before_send_transaction.call(transaction, nil)).to eq(transaction)
    end
  end
end
