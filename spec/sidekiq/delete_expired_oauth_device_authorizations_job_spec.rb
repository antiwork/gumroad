# frozen_string_literal: true

require "spec_helper"

describe DeleteExpiredOauthDeviceAuthorizationsJob do
  describe "#perform" do
    it "deletes expired device authorizations in batches" do
      stub_const("#{described_class}::DELETION_BATCH_SIZE", 1)

      expired_pending = create(:oauth_device_authorization, expires_at: 1.second.ago)
      expired_consumed = create(:oauth_device_authorization, status: OauthDeviceAuthorization::STATUS_CONSUMED, expires_at: 1.second.ago)
      expired_denied = create(:oauth_device_authorization, status: OauthDeviceAuthorization::STATUS_DENIED, expires_at: 1.second.ago)
      active_authorization = create(:oauth_device_authorization, expires_at: 1.day.from_now)

      expect do
        described_class.new.perform
      end.to change { OauthDeviceAuthorization.count }.by(-3)

      expect { expired_pending.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect { expired_consumed.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect { expired_denied.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect(active_authorization.reload).to be_present
    end

    it "keeps approved device authorizations until their poll interval past expiry has passed" do
      freeze_time
      interval = OauthDeviceAuthorization::POLL_INTERVAL.to_i
      approved_attributes = { status: OauthDeviceAuthorization::STATUS_APPROVED, resource_owner: create(:user), poll_interval_seconds: interval }

      in_grace = create(:oauth_device_authorization, **approved_attributes, expires_at: 1.second.ago, approved_at: 2.seconds.ago)
      past_grace = create(:oauth_device_authorization, **approved_attributes, expires_at: interval.seconds.ago, approved_at: (interval + 1).seconds.ago)
      without_approved_at = create(:oauth_device_authorization, **approved_attributes, expires_at: 1.second.ago, approved_at: nil)

      expect do
        described_class.new.perform
      end.to change { OauthDeviceAuthorization.count }.by(-2)

      expect(in_grace.reload).to be_present
      expect { past_grace.reload }.to raise_error(ActiveRecord::RecordNotFound)
      expect { without_approved_at.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
