# frozen_string_literal: true

require "test_helper"

class ApplicationPolicyTest < ActiveSupport::TestCase
  self.described_class = ApplicationPolicy



  context_ ApplicationPolicy do
  context_ ".allow_anonymous_user_access!" do
  test "does not affect other policy classes" do
        policy_class_1 = Class.new(ApplicationPolicy)
        policy_class_2 = Class.new(ApplicationPolicy)

        policy_class_1.allow_anonymous_user_access!

        expect(policy_class_1.allow_anonymous_user_access).to be true
        expect(policy_class_2.allow_anonymous_user_access).to be false
        expect(ApplicationPolicy.allow_anonymous_user_access).to be false
      end
    end

  context_ "#initialize" do
      let(:user) { create(:user) }
      let(:seller) { create(:named_seller) }

  test "assigns accessors" do
  context_ = SellerContext.new(user:, seller:)
        policy = described_class.new(context, :record)

        expect(policy.user).to eq(user)
        expect(policy.seller).to eq(seller)
        expect(policy.record).to eq(:record)
      end

  context_ "when anonymous user access is not allowed" do
  test "raises when user is nil" do
  context_ = SellerContext.new(user: nil, seller:)
          expect do
            described_class.new(context, :record)
          end.to raise_error(Pundit::NotAuthorizedError).with_message "must be logged in"
        end

  test "does not raise when user is present" do
  context_ = SellerContext.new(user:, seller:)
          expect do
            described_class.new(context, :record)
          end.not_to raise_error
        end
      end

  context_ "when anonymous user access is allowed" do
        let(:policy_class) do
          Class.new(ApplicationPolicy) do
            allow_anonymous_user_access!
          end
        end

  test "does not raise when user is nil" do
  context_ = SellerContext.new(user: nil, seller:)
          policy = policy_class.new(context, :record)

          expect(policy.user).to be_nil
          expect(policy.seller).to eq(seller)
          expect(policy.record).to eq(:record)
        end

  test "still works normally when user is present" do
  context_ = SellerContext.new(user:, seller:)
          policy = policy_class.new(context, :record)

          expect(policy.user).to eq(user)
          expect(policy.seller).to eq(seller)
          expect(policy.record).to eq(:record)
        end
      end
    end
  end
end
