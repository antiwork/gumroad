# frozen_string_literal: true

require "spec_helper"
require "sentry/test_helper"

describe ErrorNotifier do
  include Sentry::TestHelper

  around do |example|
    original_client = Sentry.get_current_client
    setup_sentry_test do |configuration|
      configuration.send_default_pii = true
    end

    example.run
  ensure
    teardown_sentry_test
    Sentry.get_current_hub.bind_client(original_client)
  end

  it "excludes ambient request data and breadcrumbs from a privacy-safe event" do
    sentinel = "raw-seller-chat-DO-NOT-SEND"
    fixed_message = "Store agent confirmation omitted proposal message id"
    request_body = { messages: [{ role: "user", content: sentinel }] }.to_json
    scope = Sentry.get_current_scope
    scope.set_rack_env(
      Rack::MockRequest.env_for(
        "/api/internal/agent/messages",
        method: "POST",
        "CONTENT_TYPE" => "application/json",
        input: request_body,
      ),
    )
    scope.add_breadcrumb(
      Sentry::Breadcrumb.new(category: "request.params", data: { messages: sentinel }),
    )
    scope.add_breadcrumb(
      Sentry::Breadcrumb.new(category: "logger", message: "Parameters: #{sentinel}"),
    )
    controller_span = Sentry::Span.new(
      transaction: nil,
      op: "view.process_action.action_controller",
    )
    controller_span.set_data(:params, { messages: sentinel })
    scope.set_span(controller_span)

    described_class.notify(
      fixed_message,
      exclude_request_context: true,
      ai_message_id: 123,
    )

    event = sentry_events.sole
    payload = event.to_json_compatible
    expect(payload.to_json).not_to include(sentinel)
    expect(payload).not_to have_key("request")
    expect(payload.dig("breadcrumbs", "values")).to eq([])
    expect(payload["message"]).to eq(fixed_message)
    expect(payload.dig("contexts", "extra")).to eq("ai_message_id" => 123)

    # sentry-ruby 6.5 runs the capture block against a duplicated scope, so the request's ambient
    # data remains available to unrelated events while this one event is stripped.
    expect(scope.rack_env.dig("rack.input").read).to eq(request_body)
    expect(scope.breadcrumbs.members.map(&:to_h).to_json).to include(sentinel)
    expect(scope.span.data.to_json).to include(sentinel)
  end
end
