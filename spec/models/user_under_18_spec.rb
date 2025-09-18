# frozen_string_literal: true

require "spec_helper"

RSpec.describe User, "under_18? method", type: :model do
  let(:user) { create(:user) }

  describe "#under_18?" do
    context "when user has no compliance info" do
      it "returns false" do
        expect(user.under_18?).to be false
      end
    end

    context "when user has compliance info but no birthday" do
      before { create(:user_compliance_info, user: user, birthday: nil) }

      it "returns false" do
        expect(user.under_18?).to be false
      end
    end

    context "when user is under 18" do
      before { create(:user_compliance_info, user: user, birthday: 16.years.ago) }

      it "returns true" do
        expect(user.under_18?).to be true
      end
    end

    context "when user is exactly 18" do
      before { create(:user_compliance_info, user: user, birthday: 18.years.ago) }

      it "returns false" do
        expect(user.under_18?).to be false
      end
    end

    context "when user is over 18" do
      before { create(:user_compliance_info, user: user, birthday: 20.years.ago) }

      it "returns false" do
        expect(user.under_18?).to be false
      end
    end

    context "when user has multiple compliance info records" do
      before do
        create(:user_compliance_info, user: user, birthday: 20.years.ago, deleted_at: Time.current)
        create(:user_compliance_info, user: user, birthday: 16.years.ago)
      end

      it "uses the alive (non-deleted) compliance info" do
        expect(user.under_18?).to be true
      end
    end
  end
end
