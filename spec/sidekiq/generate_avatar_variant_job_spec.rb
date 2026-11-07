# frozen_string_literal: true

require "spec_helper"

describe GenerateAvatarVariantJob do
  describe "#perform" do
    def avatar_variant_record(user)
      blob = user.reload.avatar.blob
      blob.variant_records.find_by(variation_digest: blob.variant(User::AVATAR_VARIANT_TRANSFORMATIONS).variation.digest)
    end

    it "processes the 400x400 avatar variant ahead of the first page view" do
      user = create(:user, :with_avatar)
      expect(avatar_variant_record(user)).to be_nil

      described_class.new.perform(user.id)

      expect(avatar_variant_record(user).image).to be_attached
    end

    it "does nothing for a user without an avatar" do
      expect { described_class.new.perform(create(:user).id) }.not_to raise_error
    end

    it "does nothing for a user that no longer exists" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end

    it "gives up without retrying when the uploaded avatar is gone from storage" do
      user = create(:user, :with_avatar)
      user.avatar.blob.service.delete(user.avatar.key)

      expect { described_class.new.perform(user.id) }.not_to raise_error
      expect(avatar_variant_record(user)).to be_nil
    end
  end

  describe "job options" do
    it "runs on the low queue, one job per user at a time" do
      expect(described_class.get_sidekiq_options).to include("lock" => :until_executed, "queue" => :low)
    end
  end
end
