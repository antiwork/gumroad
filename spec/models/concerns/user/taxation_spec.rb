# frozen_string_literal: true

require "spec_helper"

describe User::Taxation do
  include PaymentsHelper

  before do
    @user = create(:user)
  end

  describe "#eligible_for_1099_k?", :vcr do
    let(:year) { Date.current.year }

    before do
      create(:merchant_account_stripe, user: @user)
      create(:tos_agreement, user: @user)

      10.times do
        create(:purchase,
               seller: @user,
               total_transaction_cents: [10_00, 15_00, 20_00].sample,
               created_at: Date.current.in_time_zone(@user.timezone),
               succeeded_at: Date.current.in_time_zone(@user.timezone),
               link: create(:product, user: @user))
      end

      # To simulate eligibility
      stub_const("#{described_class}::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 100_00)
      stub_const("#{described_class}::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 5)
    end

    context "when user is not from the US" do
      before do
        create(:user_compliance_info_singapore, user: @user)
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when user is from an invalid compliance country" do
      before do
        create(:user_compliance_info, user: @user, country: "Aland Islands")
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when user doesn't meet the minimum sales amount" do
      it "returns false" do
        stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 100_000)
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when user doesn't meet the minimum sales count" do
      it "returns false" do
        stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 100)
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "for an year with different sales threshold than default" do
      context "when user doesn't meet the minimum sales amount" do
        it "returns false" do
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 10_00)
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 1)
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 1000_00 })
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 1 })

          expect(@user.eligible_for_1099_k?(year)).to eq(false)
        end
      end

      context "when user doesn't meet the minimum sales count" do
        it "returns false" do
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 10_00)
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 1)
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 10_00 })
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 100 })

          expect(@user.eligible_for_1099_k?(year)).to eq(false)
        end
      end

      context "when user meets the minimum sales amount and count" do
        it "returns true" do
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 1000_00)
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING", 100)
          stub_const("User::Taxation::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 10_00 })
          stub_const("User::Taxation::MIN_SALE_COUNT_FOR_1099_K_FEDERAL_FILING_FOR_YEAR", { year => 1 })

          expect(@user.eligible_for_1099_k?(year)).to eq(true)
        end
      end
    end

    context "when user is suspended" do
      before do
        create(:user_compliance_info, user: @user)
        @user.user_risk_state = "suspended_for_fraud"
        @user.save!
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when user is compliant" do
      before do
        create(:user_compliance_info, user: @user)
      end

      it "returns true" do
        expect(@user.eligible_for_1099_k?(year)).to eq(true)
      end
    end

    context "when sales amount is above threshold but non-refunded sales amount is not" do
      before do
        create(:user_compliance_info, user: @user)
        @user.sales.each { _1.update!(stripe_refunded: true) }
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when sales amount is above threshold but non-disputed sales amount is not" do
      before do
        create(:user_compliance_info, user: @user)
        @user.sales.each { _1.update!(chargeback_date: Date.current) }
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when sales amount is above threshold but non-Connect sales amount is not" do
      before do
        create(:user_compliance_info, user: @user)
        @user.sales.each { _1.id % 2 == 0 ? _1.update!(paypal_order_id: SecureRandom.hex) : _1.update!(merchant_account_id: create(:merchant_account_stripe_connect, user: @user).id) }
        stub_const("#{described_class}::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 1)
      end

      it "returns false" do
        expect(@user.eligible_for_1099_k?(year)).to eq(false)
      end
    end

    context "when sales amount is above state filing threshold" do
      before do
        create(:user_compliance_info, user: @user, state: "VA")
        stub_const("#{described_class}::MIN_SALE_AMOUNT_FOR_1099_K_FEDERAL_FILING", 1000_00)
        stub_const("#{described_class}::MIN_SALE_AMOUNTS_FOR_1099_K_STATE_FILINGS", { "VA" => 60_00 })
      end

      it "returns true" do
        expect(@user.eligible_for_1099_k_federal_filing?(year)).to eq(false)
        expect(@user.eligible_for_1099_k_state_filing?(year)).to eq(true)
        expect(@user.eligible_for_1099_k?(year)).to eq(true)
      end
    end
  end

  describe "#eligible_for_1099_misc?", :vcr do
    let(:year) { Date.current.year }

    before do
      create(:merchant_account_stripe, user: @user)
      create(:tos_agreement, user: @user)
      @affiliate = create(
        :direct_affiliate,
        affiliate_user: @user,
        affiliate_basis_points: [15_00, 20_00].sample
      )

      10.times do
        create(:purchase, price_cents: 100_00,
                          affiliate: @affiliate,
                          created_at: Date.current.in_time_zone(@user.timezone),
                          succeeded_at: Date.current.in_time_zone(@user.timezone))
      end

      # To simulate eligibility
      stub_const("#{described_class}::MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING", 100_00)
    end

    context "when user is not from the US" do
      before do
        create(:user_compliance_info_singapore, user: @user)
      end

      it "returns false" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when user is from an invalid compliance country" do
      before do
        create(:user_compliance_info, user: @user, country: "Aland Islands")
      end

      it "returns false" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when user doesn't meet the minimum affiliate sales amount" do
      it "returns false" do
        stub_const("User::Taxation::MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING", 250_00)
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when user is suspended" do
      before do
        @user.user_risk_state = "suspended_for_fraud"
        @user.save!
      end

      it "returns false" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when user is compliant" do
      before do
        create(:user_compliance_info, user: @user)
      end

      it "returns true" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(true)
      end
    end

    context "when affiliate sales amount is above threshold but non-refunded amount is not" do
      before do
        create(:user_compliance_info, user: @user)
        Purchase.where(affiliate_id: @affiliate.id).each { _1.update!(stripe_refunded: true) }
      end

      it "returns false" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when affiliate sales amount is above threshold but non-disputed amount is not" do
      before do
        create(:user_compliance_info, user: @user)
        Purchase.where(affiliate_id: @affiliate.id).each { _1.update!(chargeback_date: Date.current) }
      end

      it "returns false" do
        expect(@user.eligible_for_1099_misc?(year)).to eq(false)
      end
    end

    context "when affiliate amount is above state filing threshold" do
      before do
        create(:user_compliance_info, user: @user, state: "AR")
        stub_const("#{described_class}::MIN_AFFILIATE_AMOUNT_FOR_1099_MISC_FEDERAL_FILING", 1000_00)
        stub_const("#{described_class}::MIN_AFFILIATE_AMOUNTS_FOR_1099_MISC_STATE_FILINGS", { "AR" => 10_00 })
      end

      it "returns true" do
        expect(@user.eligible_for_1099_misc_federal_filing?(year)).to eq(false)
        expect(@user.eligible_for_1099_misc_state_filing?(year)).to eq(true)
        expect(@user.eligible_for_1099_misc?(year)).to eq(true)
      end
    end
  end

  describe "#eligible_for_1099?", :vcr do
    let(:year) { Date.current.year }
    before do
      allow_any_instance_of(User).to receive(:is_a_non_suspended_creator_from_usa?).and_return(true)
    end

    it "returns true if eligible for 1099-K and not 1099-MISC" do
      allow_any_instance_of(User).to receive(:eligible_for_1099_k?).and_return(true)
      allow_any_instance_of(User).to receive(:eligible_for_1099_misc?).and_return(false)

      expect(create(:user).eligible_for_1099?(year)).to be true
    end

    it "returns true if eligible for 1099-MISC and not 1099-K" do
      allow_any_instance_of(User).to receive(:eligible_for_1099_k?).and_return(false)
      allow_any_instance_of(User).to receive(:eligible_for_1099_misc?).and_return(true)

      expect(create(:user).eligible_for_1099?(year)).to be true
    end

    it "returns false if eligible for neither 1099-K nor 1099-MISC" do
      allow_any_instance_of(User).to receive(:eligible_for_1099_k?).and_return(false)
      allow_any_instance_of(User).to receive(:eligible_for_1099_misc?).and_return(false)

      expect(create(:user).eligible_for_1099?(year)).to be false
    end

    it "returns true if eligible for both 1099-K and 1099-MISC" do
      allow_any_instance_of(User).to receive(:eligible_for_1099_k?).and_return(true)
      allow_any_instance_of(User).to receive(:eligible_for_1099_misc?).and_return(true)

      expect(create(:user).eligible_for_1099?(year)).to be true
    end
  end

  describe "#is_a_non_suspended_creator_from_usa?", :vcr do
    let(:year) { Date.current.year }

    context "when user is not from the US" do
      before do
        create(:user_compliance_info_singapore, user: @user)
      end

      it "returns false" do
        expect(@user.is_a_non_suspended_creator_from_usa?).to eq(false)
      end
    end

    context "when user is from an invalid compliance country" do
      before do
        create(:user_compliance_info, user: @user, country: "Aland Islands")
      end

      it "returns false" do
        expect(@user.is_a_non_suspended_creator_from_usa?).to eq(false)
      end
    end

    context "when user is compliant and from US" do
      before do
        create(:user_compliance_info, user: @user)
      end

      it "returns true" do
        expect(@user.is_a_non_suspended_creator_from_usa?).to eq(true)
      end
    end
  end

  describe "#from_us?" do
    context "when user is from the United States" do
      before do
        create(:user_compliance_info, user: @user)
      end

      it "returns true" do
        expect(@user.from_us?).to eq(true)
      end
    end

    context "when user is from Singapore" do
      before do
        create(:user_compliance_info_singapore, user: @user)
      end

      it "returns false" do
        expect(@user.from_us?).to eq(false)
      end
    end

    context "when user compliance is empty" do
      before do
        create(:user_compliance_info_empty, user: @user)
      end

      it "returns false" do
        expect(@user.from_us?).to eq(false)
      end
    end

    context "when user compliance is missing" do
      it "returns false" do
        expect(@user.from_us?).to eq(false)
      end
    end
  end
end
