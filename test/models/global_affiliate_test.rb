# frozen_string_literal: true

require "test_helper"

class GlobalAffiliateTest < ActiveSupport::TestCase
  self.described_class = GlobalAffiliate



  context_ GlobalAffiliate do
  context_ "validations" do
  context_ "affiliate_basis_points" do
  test "requires affiliate_basis_points to be present" do
          affiliate = create(:user).global_affiliate # sets affiliate basis points in pre-validation hook on creation
          affiliate.affiliate_basis_points = nil
          expect(affiliate).not_to be_valid
          expect(affiliate.errors.full_messages).to include "Affiliate basis points can't be blank"
        end
      end

  context_ "affiliate_user_id" do
        let(:user) { create(:user) }
        let!(:global_affiliate) { user.global_affiliate }

  test "requires affiliate_user_id to be unique" do
          duplicate_affiliate = described_class.new(affiliate_user: user)
          expect(duplicate_affiliate).not_to be_valid
          expect(duplicate_affiliate.errors.full_messages).to include "Affiliate user has already been taken"
        end

  test "allows multiple direct affiliates for that user" do
          create_list(:direct_affiliate, 2, affiliate_user: user).each do |affiliate|
            expect(affiliate).to be_valid
          end
        end
      end

  context_ "eligible_for_stripe_payments" do
        let(:affiliate_user) do
          user = build(:user)
          user.save(validate: false)
          user
        end
        let(:global_affiliate) { affiliate_user.global_affiliate }

  context_ "when affiliate user has a Brazilian Stripe Connect account" do
          before do
            allow_any_instance_of(User).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
            allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(true)
          end

  test "is invalid" do
            expect(global_affiliate).not_to be_valid
            expect(global_affiliate.errors[:base]).to include(
              "This user cannot be added as an affiliate because they use a Brazilian Stripe account."
            )
          end
        end

  context_ "when the affiliate user does not have a Brazilian Stripe Connect account" do
          before do
            allow(affiliate_user).to receive(:has_brazilian_stripe_connect_account?).and_return(false)
          end

  test "is valid" do
            expect(global_affiliate).to be_valid
          end
        end
      end
    end

  context_ "lifecycle hooks" do
  context_ "before_validation :set_affiliate_basis_points" do
  test "sets affiliate basis points to the default for a new record" do
          affiliate = described_class.new(affiliate_basis_points: nil)
          affiliate.valid?
          expect(affiliate.affiliate_basis_points).to eq GlobalAffiliate::AFFILIATE_BASIS_POINTS
        end

  test "does not overwrite affiliate basis points for an existing record" do
          affiliate = create(:user).global_affiliate
          affiliate.affiliate_basis_points = 5000
          expect { affiliate.valid? }.not_to change { affiliate.affiliate_basis_points }
        end
      end
    end

  context_ ".cookie_lifetime" do
  test "returns 7 days" do
        expect(described_class.cookie_lifetime).to eq 7.days
      end
    end

  context_ "#final_destination_url" do
      let(:affiliate) { create(:user).global_affiliate }

  context_ "when product is provided" do
  test "returns the product URL" do
          product = create(:product)
          expect(affiliate.final_destination_url(product:)).to eq product.long_url
        end
      end

  context_ "when product is not provided" do
  test "returns the discover URL with the affiliate ID param" do
          expect(affiliate.final_destination_url).to eq "#{UrlService.discover_domain_with_protocol}/discover?a=#{affiliate.external_id_numeric}"
        end
      end
    end

  context_ "#eligible_for_purchase_credit?" do
      let(:affiliate) { create(:user).global_affiliate }
      let(:product) { create(:product, :recommendable) }

  test "returns true if the product is eligible for the global affiliate program, even if the purchase came through Discover" do
        expect(affiliate.eligible_for_purchase_credit?(product:, was_recommended: false)).to eq true
        expect(affiliate.eligible_for_purchase_credit?(product:, was_recommended: true)).to eq true
      end

  test "returns true if the product is eligible and the purchaser email is different from that of the affiliate" do
        expect(affiliate.eligible_for_purchase_credit?(product:, purchaser_email: "not_affiliate@example.com")).to eq true
      end

  test "returns true if the product is eligible and adult" do
        nsfw_product = create(:product, :recommendable, is_adult: true)
        expect(affiliate.eligible_for_purchase_credit?(product: nsfw_product)).to eq true
      end

  test "returns false for an ineligible product" do
        product = create(:product)
        expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
      end

  test "returns false if the affiliate is deleted" do
        affiliate.update!(deleted_at: Time.current)
        expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
      end

  test "returns false if the purchaser is the same as the affiliate (based on email exact match)" do
        expect(affiliate.eligible_for_purchase_credit?(product:, purchaser_email: affiliate.affiliate_user.email)).to eq false
      end

  test "returns false if the affiliate is suspended" do
        user = affiliate.affiliate_user
        admin = create(:admin_user)
        user.flag_for_fraud!(author_id: admin.id)
        user.suspend_for_fraud!(author_id: admin.id)
        affiliate.reload
        expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
      end

  test "returns false if the seller has disabled global affiliates" do
        product = create(:product, :recommendable)
        product.user.update!(disable_global_affiliate: true)

        expect(affiliate.eligible_for_purchase_credit?(product:)).to eq false
      end

  test "returns false if affiliated user is using a Brazilian Stripe Connect account" do
        expect(affiliate.eligible_for_credit?).to be true

        brazilian_stripe_account = create(:merchant_account_stripe_connect, user: affiliate.affiliate_user, country: "BR")
        affiliate.affiliate_user.update!(check_merchant_account_is_linked: true)
        expect(affiliate.affiliate_user.merchant_account(StripeChargeProcessor.charge_processor_id)).to eq brazilian_stripe_account

        expect(affiliate.eligible_for_credit?).to be false
      end
    end
  end
end
