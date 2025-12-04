# frozen_string_literal: true

require "spec_helper"

describe ResendFallbackTracker do
  let(:user) { create(:user) }

  before do
    ResendFallbackTracker.clear(email_type: :two_factor, user_id: user.id)
    ResendFallbackTracker.clear(email_type: :password_reset, user_id: user.id)
  end

  describe ".should_use_resend_fallback?" do
    context "when feature flag is inactive" do
      before { Feature.deactivate(:resend_fallback_for_auth_emails) }

      it "returns false" do
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be false
      end
    end

    context "when feature flag is active" do
      before { Feature.activate(:resend_fallback_for_auth_emails) }

      it "returns false when no previous email was sent" do
        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be false
      end

      it "returns false when previous email was sent more than 30 seconds ago" do
        travel_to(35.seconds.ago) do
          ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)
        end

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be false
      end

      it "returns true when previous email was sent within 30 seconds" do
        travel_to(20.seconds.ago) do
          ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)
        end

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be true
      end

      it "returns true when previous email was sent just now" do
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be true
      end

      it "tracks different email types separately" do
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be true
        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :password_reset, user_id: user.id)).to be false
      end

      it "tracks different users separately" do
        other_user = create(:user)
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: user.id)).to be true
        expect(ResendFallbackTracker.should_use_resend_fallback?(email_type: :two_factor, user_id: other_user.id)).to be false
      end
    end

    context "with invalid email_type" do
      before { Feature.activate(:resend_fallback_for_auth_emails) }

      it "raises ArgumentError" do
        expect {
          ResendFallbackTracker.should_use_resend_fallback?(email_type: :invalid_type, user_id: user.id)
        }.to raise_error(ArgumentError, "Invalid email_type: invalid_type")
      end
    end
  end

  describe ".record_email_sent" do
    it "stores the current timestamp in Redis" do
      freeze_time do
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

        stored_value = $redis.get("resend_fallback:two_factor:#{user.id}")
        expect(stored_value.to_i).to eq(Time.current.to_i)
      end
    end

    it "sets appropriate TTL on the key" do
      ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)

      ttl = $redis.ttl("resend_fallback:two_factor:#{user.id}")
      expect(ttl).to be_between(110, 120)
    end

    it "updates the timestamp on subsequent calls" do
      ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)
      first_value = $redis.get("resend_fallback:two_factor:#{user.id}").to_i

      travel_to(10.seconds.from_now) do
        ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)
        second_value = $redis.get("resend_fallback:two_factor:#{user.id}").to_i

        expect(second_value).to be > first_value
      end
    end

    context "with invalid email_type" do
      it "raises ArgumentError" do
        expect {
          ResendFallbackTracker.record_email_sent(email_type: :invalid_type, user_id: user.id)
        }.to raise_error(ArgumentError, "Invalid email_type: invalid_type")
      end
    end
  end

  describe ".clear" do
    it "removes the tracking key from Redis" do
      ResendFallbackTracker.record_email_sent(email_type: :two_factor, user_id: user.id)
      expect($redis.get("resend_fallback:two_factor:#{user.id}")).to be_present

      ResendFallbackTracker.clear(email_type: :two_factor, user_id: user.id)
      expect($redis.get("resend_fallback:two_factor:#{user.id}")).to be_nil
    end
  end
end

