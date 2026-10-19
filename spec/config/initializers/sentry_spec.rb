# frozen_string_literal: true

require "spec_helper"
require "sentry/test_helper"

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

  describe "failed Help Center contact deliveries" do
    include Sentry::TestHelper

    let(:support_text) { "Synthetic support text that must stay out of error reports." }
    let(:screenshot) { "\x89PNG\r\n\x1A\n".b + Random.bytes(64) }
    let(:contact_args) do
      {
        email: "buyer@example.com",
        category: "technical issue",
        message: support_text,
        user_id: nil,
        referrer_path: "/help",
        attachments: [{ filename: "image.png", mime_type: "image/png", content: Base64.strict_encode64(screenshot) }],
      }
    end

    before do
      setup_sentry_test
      # Synthetic failure in place of SMTP: delivery stays on the test transport.
      allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::ReadTimeout)
    end

    after { teardown_sentry_test }

    def wire(job_data)
      JSON.parse(JSON.generate(job_data.select { |key, _| key.is_a?(String) }))
    end

    def enqueued_job_data
      ActiveJob::Base.queue_adapter.enqueued_jobs.last
    end

    # Replays each attempt the way Sidekiq would pull it back out of Redis,
    # until MailDeliveryJob's retry_on gives up and re-raises.
    def run_until_retries_give_up(job_data)
      1.upto(20) do |attempt|
        ActiveJob::Base.execute(wire(job_data))
      rescue Net::ReadTimeout
        return attempt
      else
        job_data = enqueued_job_data
      end
      raise "retry_on never gave up"
    end

    def enqueue_contact_job(**overrides)
      SupportContactMailer.contact_form(**contact_args, **overrides).deliver_later
      enqueued_job_data
    end

    def sent_envelope
      envelope = sentry_transport.envelopes.sole
      data, items = sentry_transport.serialize_envelope(envelope)
      expect(items.map(&:type)).to eq(["event"])
      data
    end

    it "reports the failure without the screenshots or the message" do
      job_data = enqueue_contact_job
      expect(job_data[:job]).to eq(SupportContactMailDeliveryJob)

      expect(run_until_retries_give_up(job_data)).to eq(10)

      event = sentry_events.sole
      expect(event.exception.values.sole.type).to eq("Net::ReadTimeout")
      expect(event.extra[:active_job]).to eq("SupportContactMailDeliveryJob")
      expect(event.extra[:arguments].first(3)).to eq(["SupportContactMailer", "contact_form", "deliver_now"])
      kwargs = event.extra[:arguments].last[:args].sole
      expect(kwargs).to include(email: "buyer@example.com", category: "technical issue", referrer_path: "/help", attachments: 1, message: support_text.length)

      data = sent_envelope
      expect(data).not_to include(Base64.strict_encode64(screenshot).first(40))
      expect(data).not_to include(support_text)
    end

    it "keeps the report deliverable at the largest submission the form accepts" do
      screenshots = Array.new(2) { "\x89PNG\r\n\x1A\n".b + Random.bytes(HelpCenter::ContactsController::MAX_ATTACHMENT_BYTES - 8) }
      job_data = enqueue_contact_job(
        message: "a" * HelpCenter::ContactsController::MAX_MESSAGE_LENGTH,
        attachments: screenshots.map { { filename: "image.png", mime_type: "image/png", content: Base64.strict_encode64(_1) } }
      )

      run_until_retries_give_up(job_data)

      expect(JSON.generate(sentry_events.sole.extra).bytesize).to be < 1_000
      expect(sent_envelope.bytesize).to be < Sentry::Envelope::Item::MAX_SERIALIZED_PAYLOAD_SIZE
    end

    it "also redacts contact jobs queued under the shared delivery job before this change" do
      allow(SupportContactMailer).to receive(:delivery_job).and_return(MailDeliveryJob)
      job_data = enqueue_contact_job
      expect(job_data[:job]).to eq(MailDeliveryJob)

      run_until_retries_give_up(job_data)

      expect(sentry_events.sole.extra[:active_job]).to eq("MailDeliveryJob")
      data = sent_envelope
      expect(data).not_to include(Base64.strict_encode64(screenshot).first(40))
      expect(data).not_to include(support_text)
    end

    it "leaves other mail jobs' arguments as the integration reported them" do
      user = create(:user)
      TwoFactorAuthenticationMailer.authentication_token(user.id).deliver_later

      run_until_retries_give_up(enqueued_job_data)

      expect(sentry_events.sole.extra[:arguments]).to eq(["TwoFactorAuthenticationMailer", "authentication_token", "deliver_now", { args: [user.id] }])
    end

    it "keeps retrying quietly before the last attempt" do
      job_data = enqueue_contact_job

      expect { ActiveJob::Base.execute(wire(job_data)) }.not_to raise_error

      expect(enqueued_job_data["exception_executions"]).to eq("[Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy]" => 1)
      expect(sentry_events).to be_empty
    end
  end
end
