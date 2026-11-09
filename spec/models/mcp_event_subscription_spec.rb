# frozen_string_literal: true

require "spec_helper"

describe McpEventSubscription do
  let(:seller) { create(:user) }
  let(:application) { create(:oauth_application) }
  let(:secret) { whsec(32) }

  def whsec(bytes)
    "whsec_#{Base64.strict_encode64(SecureRandom.bytes(bytes))}"
  end

  def subscribe!(**overrides)
    described_class.subscribe!(
      user: seller,
      oauth_application: application,
      event_name: described_class::SALE_CREATED,
      arguments: {},
      callback_url: "https://example.com/hooks/mcp",
      secret:,
      **overrides
    )
  end

  describe ".subscribe!", :freeze_time do
    it "grants the longest lease when the client suggests no lifetime" do
      subscription = subscribe!

      expect(subscription).to be_persisted
      expect(subscription.expires_at).to eq(1.day.from_now)
      expect(subscription.public_id).to match(/\Asub_\h{32}\z/)
    end

    it "holds a suggested lifetime inside the bounds" do
      expect(subscribe!(ttl: 1.hour).expires_at).to eq(1.hour.from_now)
      expect(subscribe!(ttl: 10).expires_at).to eq(5.minutes.from_now)
      expect(subscribe!(ttl: 1.week).expires_at).to eq(1.day.from_now)
    end

    it "refreshes the row for the same key, whatever the order and key type of the arguments, and replaces the secret" do
      first = subscribe!(arguments: { "product_id" => "abc", "filters" => [{ "kind" => "paid", "minimum" => 1 }] }, ttl: 5.minutes)
      new_secret = whsec(24)

      second = subscribe!(arguments: { filters: [{ minimum: 1, kind: "paid" }], product_id: "abc" }, secret: new_secret, ttl: 1.hour)

      expect(described_class.count).to eq(1)
      expect(second.id).to eq(first.id)
      expect(second.public_id).to eq(first.public_id)
      expect(second.reload.secret).to eq(new_secret)
      expect(second.expires_at).to eq(1.hour.from_now)
    end

    it "keeps subscriptions apart when the seller, application, callback URL or arguments differ" do
      subscribe!
      subscribe!(user: create(:user))
      subscribe!(oauth_application: create(:oauth_application))
      subscribe!(callback_url: "https://example.org/hooks/mcp")
      subscribe!(arguments: { "product_id" => "abc" })

      expect(described_class.count).to eq(5)
      expect(described_class.all.map(&:public_id).uniq.size).to eq(5)
    end

    it "revives an expired subscription under the same id" do
      expired = subscribe!
      expired.update_columns(expires_at: 1.minute.ago)

      revived = subscribe!

      expect(revived.id).to eq(expired.id)
      expect(described_class.live).to eq([revived])
    end

    it "refuses a callback URL that is not https, or that carries credentials" do
      ["http://example.com/hooks/mcp", "example.com/hooks/mcp", "https://", "not a url", "", "https://user:password@example.com/hooks/mcp"].each do |callback_url|
        expect { subscribe!(callback_url:) }.to raise_error(ActiveRecord::RecordInvalid, /Callback url must be an https URL without credentials/)
      end
      expect(described_class.count).to eq(0)
    end

    it "refuses a change to the key of an existing subscription" do
      subscription = subscribe!

      expect { subscription.update!(callback_url: "https://example.org/hooks/mcp") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    end

    it "refuses a callback URL longer than the column holds" do
      callback_url = "https://example.com/#{"a" * described_class::MAX_CALLBACK_URL_LENGTH}"

      expect { subscribe!(callback_url:) }.to raise_error(ActiveRecord::RecordInvalid, /Callback url is too long/)
    end

    it "accepts a secret of 24 to 64 random bytes and refuses any other" do
      expect(subscribe!(secret: whsec(24))).to be_persisted
      expect(subscribe!(secret: whsec(64))).to be_persisted

      [whsec(23), whsec(65), Base64.strict_encode64(SecureRandom.bytes(32)), "whsec_not base64", "whsec_", nil].each do |bad_secret|
        expect { subscribe!(secret: bad_secret) }.to raise_error(ActiveRecord::RecordInvalid, /Secret must be whsec_ followed by the base64 of 24 to 64 random bytes/)
      end
    end

    it "refuses an event name it does not publish" do
      expect { subscribe!(event_name: "refund.created") }.to raise_error(ActiveRecord::RecordInvalid, /Event name is not included in the list/)
    end

    it "refuses arguments that are not an object, or that are too large" do
      expect { subscribe!(arguments: ["abc"]) }.to raise_error(ActiveRecord::RecordInvalid, /Arguments must be an object/)
      expect { subscribe!(arguments: { "product_id" => "a" * described_class::MAX_ARGUMENTS_BYTES }) }
        .to raise_error(ActiveRecord::RecordInvalid, /Arguments must be at most 1024 bytes of JSON/)
    end

    it "keeps the secret out of the inspected record" do
      expect(subscribe!.full_inspect).to include("secret: [FILTERED]")
    end

    it "refreshes the winner's row when two first subscribes for one key race" do
      # The other request commits between this one's lookup and its insert.
      allow(described_class).to receive(:find_by).and_wrap_original do
        allow(described_class).to receive(:find_by).and_call_original
        create(:mcp_event_subscription, user: seller, oauth_application: application, expires_at: 1.minute.from_now)
        nil
      end

      subscription = subscribe!

      expect(described_class.count).to eq(1)
      expect(subscription.reload.secret).to eq(secret)
      expect(subscription.expires_at).to eq(1.day.from_now)
    end

    context "when the connection holds the limit of live subscriptions" do
      before { stub_const("McpEventSubscription::MAX_LIVE_PER_CONNECTION", 2) }

      let!(:first) { subscribe!(arguments: { "product_id" => "a" }) }
      let!(:second) { subscribe!(arguments: { "product_id" => "b" }) }

      it "refuses another subscription" do
        expect { subscribe!(arguments: { "product_id" => "c" }) }.to raise_error(ActiveRecord::RecordInvalid, /already has 2 live event subscriptions/)
        expect(described_class.count).to eq(2)
      end

      it "refreshes a live subscription" do
        expect(subscribe!(arguments: { "product_id" => "a" }, ttl: 1.hour).expires_at).to eq(1.hour.from_now)
      end

      it "gives the slot of an expired subscription to a new one, and then refuses to revive the expired one" do
        first.update_columns(expires_at: 1.minute.ago)

        expect(subscribe!(arguments: { "product_id" => "c" })).to be_persisted
        expect { subscribe!(arguments: { "product_id" => "a" }) }.to raise_error(ActiveRecord::RecordInvalid, /already has 2 live event subscriptions/)
        expect(first.reload.expires_at).to eq(1.minute.ago)
      end

      it "leaves another application's and another seller's subscriptions out of the count" do
        expect(subscribe!(oauth_application: create(:oauth_application))).to be_persisted
        expect(subscribe!(user: create(:user))).to be_persisted
      end
    end
  end

  describe ".live" do
    it "leaves out a subscription whose lease has ended" do
      live = create(:mcp_event_subscription)
      create(:mcp_event_subscription, expires_at: 1.second.ago)

      expect(described_class.live).to eq([live])
    end
  end
end
