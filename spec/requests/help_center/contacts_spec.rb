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
        referrer_path: "/help/article/13-getting-paid"
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
