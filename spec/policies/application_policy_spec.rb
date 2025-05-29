# frozen_string_literal: true

require "spec_helper"

describe ApplicationPolicy do
  describe ".allow_anonymous_user_access!" do
    it "does not affect other policy classes" do
      policy_class_1 = Class.new(ApplicationPolicy)
      policy_class_2 = Class.new(ApplicationPolicy)

      policy_class_1.allow_anonymous_user_access!

      expect(policy_class_1.allow_anonymous_user_access).to be true
      expect(policy_class_2.allow_anonymous_user_access).to be false
      expect(ApplicationPolicy.allow_anonymous_user_access).to be false
    end
  end

  describe "#initialize" do
    let(:user) { create(:user) }
    let(:seller) { create(:named_seller) }

    it "assigns accessors" do
      context = SellerContext.new(user:, seller:)
      policy = described_class.new(context, :record)

      expect(policy.user).to eq(user)
      expect(policy.seller).to eq(seller)
      expect(policy.record).to eq(:record)
    end

    context "when anonymous user access is not allowed" do
      it "raises when user is nil" do
        context = SellerContext.new(user: nil, seller:)
        expect do
          described_class.new(context, :record)
        end.to raise_error(Pundit::NotAuthorizedError).with_message "must be logged in"
      end

      it "does not raise when user is present" do
        context = SellerContext.new(user:, seller:)
        expect do
          described_class.new(context, :record)
        end.not_to raise_error
      end
    end

    context "when anonymous user access is allowed" do
      let(:policy_class) do
        Class.new(ApplicationPolicy) do
          allow_anonymous_user_access!
        end
      end

      it "does not raise when user is nil" do
        context = SellerContext.new(user: nil, seller:)
        policy = policy_class.new(context, :record)

        expect(policy.user).to be_nil
        expect(policy.seller).to eq(seller)
        expect(policy.record).to eq(:record)
      end

      it "still works normally when user is present" do
        context = SellerContext.new(user:, seller:)
        policy = policy_class.new(context, :record)

        expect(policy.user).to eq(user)
        expect(policy.seller).to eq(seller)
        expect(policy.record).to eq(:record)
      end
    end
  end
end
