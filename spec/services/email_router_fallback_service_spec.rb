# frozen_string_literal: true

require "spec_helper"

describe EmailRouterFallbackService do
  let(:user) { create(:user) }

  before do
    EmailRouterFallbackService.clear(user:)
  end

  describe ".email_provider_for_two_factor" do
    context "when feature flag is inactive" do
      before { Feature.deactivate(:resend_fallback_for_auth_emails) }

      it "returns nil" do
        EmailRouterFallbackService.record_email_sent(user:)

        expect(EmailRouterFallbackService.email_provider_for_two_factor(user:)).to be_nil
      end
    end

    context "when feature flag is active" do
      before { Feature.activate(:resend_fallback_for_auth_emails) }

      it "returns nil when no previous email was sent" do
        expect(EmailRouterFallbackService.email_provider_for_two_factor(user:)).to be_nil
      end

      it "returns Resend provider when Redis key exists" do
        EmailRouterFallbackService.record_email_sent(user:)

        expect(EmailRouterFallbackService.email_provider_for_two_factor(user:)).to eq MailerInfo::EMAIL_PROVIDER_RESEND
      end

      it "tracks different users separately" do
        other_user = create(:user)
        EmailRouterFallbackService.record_email_sent(user:)

        expect(EmailRouterFallbackService.email_provider_for_two_factor(user:)).to eq MailerInfo::EMAIL_PROVIDER_RESEND
        expect(EmailRouterFallbackService.email_provider_for_two_factor(user: other_user)).to be_nil
      end
    end
  end

  describe ".record_email_sent" do
    it "stores the current timestamp in Redis" do
      freeze_time do
        EmailRouterFallbackService.record_email_sent(user:)

        stored_value = $redis.get(RedisKey.email_router_fallback(user.id))
        expect(Time.zone.parse(stored_value)).to eq(Time.current)
      end
    end

    it "sets 5 minute TTL on the key" do
      EmailRouterFallbackService.record_email_sent(user:)

      ttl = $redis.ttl(RedisKey.email_router_fallback(user.id))
      expect(ttl).to be_between(290, 300)
    end
  end

  describe ".clear" do
    it "removes the tracking key from Redis" do
      EmailRouterFallbackService.record_email_sent(user:)
      expect($redis.get(RedisKey.email_router_fallback(user.id))).to be_present

      EmailRouterFallbackService.clear(user:)
      expect($redis.get(RedisKey.email_router_fallback(user.id))).to be_nil
    end
  end
end
