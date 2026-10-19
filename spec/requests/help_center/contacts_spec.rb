# frozen_string_literal: true

require "spec_helper"

describe "Help Center contact form", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:valid_params) do
    {
      email: "buyer@example.com",
      category: "payouts",
      message: "My payout hasn't arrived and it's been over a week now.",
      referrer_path: "/help/article/13-getting-paid"
    }
  end

  before do
    allow_any_instance_of(ActionDispatch::Request).to receive(:host).and_return(VALID_REQUEST_HOSTS.first)
  end

  describe "POST /help/contact" do
    it "enqueues a support email and returns success" do
      expect do
        post help_center_contact_path, params: valid_params
      end.to have_enqueued_mail(SupportContactMailer, :contact_form).with(
        email: "buyer@example.com",
        category: "payouts",
        message: "My payout hasn't arrived and it's been over a week now.",
        user_id: nil,
        referrer_path: "/help/article/13-getting-paid",
        attachments: []
      )

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
    end

    context "when the user is logged in" do
      let(:user) { create(:user) }

      before { sign_in user }

      it "attaches the user's id to the enqueued email" do
        # `protect_from_forgery` null-sessions unverified POSTs, which would
        # silently drop the logged-in user — so submit with a real CSRF token,
        # the way the browser form does.
        get help_center_root_path
        csrf_token = Nokogiri::HTML(response.body).at_css("meta[name='csrf-token']")["content"]

        expect do
          post help_center_contact_path, params: valid_params.merge(authenticity_token: csrf_token)
        end.to have_enqueued_mail(SupportContactMailer, :contact_form).with(
          hash_including(user_id: user.id)
        )

        expect(response).to have_http_status(:ok)
      end
    end

    it "rejects an invalid email" do
      expect do
        post help_center_contact_path, params: valid_params.merge(email: "not-an-email")
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Please enter a valid email address.")
    end

    it "rejects an unknown category" do
      expect do
        post help_center_contact_path, params: valid_params.merge(category: "spam")
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Please select a category.")
    end

    it "rejects an empty or too-short message" do
      expect do
        post help_center_contact_path, params: valid_params.merge(message: "help")
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("at least")
    end

    it "rejects an overly long message" do
      expect do
        post help_center_contact_path, params: valid_params.merge(message: "a" * 10_001)
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "silently drops honeypot submissions with a fake success" do
      expect do
        post help_center_contact_path, params: valid_params.merge(website: "https://spam.example.com")
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)
    end

    it "does not forward an unsafe referrer path" do
      expect do
        post help_center_contact_path, params: valid_params.merge(referrer_path: "https://evil.example.com/phish")
      end.to have_enqueued_mail(SupportContactMailer, :contact_form).with(
        hash_including(referrer_path: nil)
      )
    end
  end

  describe "image attachments" do
    # Smallest valid 1x1 PNG; MIME detection reads the magic bytes, so the test
    # does not need a real screenshot.
    let(:png_bytes) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==") }
    let(:upload_dir) { Rails.root.join("tmp", "contact-spec-#{SecureRandom.hex(4)}") }

    after { FileUtils.rm_rf(upload_dir) }

    def image_upload(bytes: nil, filename: "screenshot.png", content_type: "image/png")
      FileUtils.mkdir_p(upload_dir)
      path = upload_dir.join("#{SecureRandom.hex(4)}-#{filename}")
      File.binwrite(path, bytes || png_bytes)
      Rack::Test::UploadedFile.new(path.to_s, content_type, true, original_filename: filename)
    end

    it "forwards the image bytes to the mailer so support can open the screenshot" do
      post help_center_contact_path, params: valid_params.merge(attachments: [image_upload])

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["success"]).to be(true)

      # MailDeliveryJob wraps the mailer kwargs one level deep: [class, method, when, { args: [...] }].
      delivery_args = ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args].last.fetch("args").last
      attachment = delivery_args["attachments"].first
      expect(attachment["filename"]).to eq("screenshot.png")
      expect(attachment["mime_type"]).to eq("image/png")
      expect(Base64.strict_decode64(attachment["content"])).to eq(png_bytes)
    end

    it "rejects a file whose declared type is an image but whose bytes are not" do
      expect do
        post help_center_contact_path, params: valid_params.merge(attachments: [image_upload(bytes: "definitely not a png", filename: "fake.png")])
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("PNG, JPG, GIF or WEBP")
    end

    it "rejects more than three images" do
      expect do
        post help_center_contact_path, params: valid_params.merge(attachments: Array.new(4) { image_upload })
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("at most 3")
    end

    it "rejects an image over the per-file size cap" do
      stub_const("HelpCenter::ContactsController::MAX_ATTACHMENT_BYTES", 10.bytes)

      expect do
        post help_center_contact_path, params: valid_params.merge(attachments: [image_upload])
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("smaller than")
    end

    it "rejects attachments that exceed the total size cap" do
      stub_const("HelpCenter::ContactsController::MAX_TOTAL_ATTACHMENT_BYTES", 10.bytes)

      expect do
        post help_center_contact_path, params: valid_params.merge(attachments: [image_upload])
      end.not_to have_enqueued_mail(SupportContactMailer, :contact_form)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("total")
    end
  end

  describe "rate limiting" do
    def contact_request(path)
      Rack::Attack::Request.new(
        Rack::MockRequest.env_for(
          path,
          method: "POST",
          params: valid_params,
          "HTTP_CF_CONNECTING_IP" => "203.0.113.77"
        )
      )
    end

    it "throttles POST /help/contact by IP" do
      throttled = contact_request("/help/contact")

      Rack::Attack.cache.store.flushdb
      Rack::Attack.reset!

      travel_to(Time.current) do
        3.times do |i|
          expect(Rack::Attack.configuration.throttled?(throttled)).to be(false), "request #{i + 1} unexpectedly throttled"
        end
        expect(Rack::Attack.configuration.throttled?(throttled)).to be(true)
      end
    ensure
      Rack::Attack.cache.store.flushdb
      Rack::Attack.reset!
    end

    it "counts format-suffixed paths against the same limit" do
      # The route accepts any format suffix (`/help/contact.xml`, ...), so the
      # throttle must both match those paths and share one counter across them —
      # otherwise each suffix would hand an attacker a fresh budget.
      Rack::Attack.cache.store.flushdb
      Rack::Attack.reset!

      travel_to(Time.current) do
        expect(Rack::Attack.configuration.throttled?(contact_request("/help/contact"))).to be(false)
        expect(Rack::Attack.configuration.throttled?(contact_request("/help/contact.xml"))).to be(false)
        expect(Rack::Attack.configuration.throttled?(contact_request("/help/contact.txt"))).to be(false)
        expect(Rack::Attack.configuration.throttled?(contact_request("/help/contact.json"))).to be(true)
      end
    ensure
      Rack::Attack.cache.store.flushdb
      Rack::Attack.reset!
    end
  end
end
