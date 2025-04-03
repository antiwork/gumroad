# frozen_string_literal: true

require "spec_helper"

describe "Purchase Zip Scenarios", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  let(:ip_address) { "24.7.90.214" }
  let(:initial_balance) { 200 }
  let(:user) { create(:user, unpaid_balance_cents: initial_balance) }
  let(:link) { create(:product, user:) }
  let(:chargeable) { create :chargeable }

  describe "zip_tax_rate associations" do
    before do
      link = create(:product)
      @purchase1 = create(:purchase, link:, price_cents: 100)
      @purchase2 = create(:purchase, link:, price_cents: 100)
      @zip_tax_rate1 = create(:zip_tax_rate)
    end

    it "associates a single zip tax rate with a purchase (when eligible)" do
      @purchase1.zip_tax_rate = @zip_tax_rate1
      @purchase2.zip_tax_rate = @zip_tax_rate1

      @purchase1.save!
      @purchase2.save!

      expect(@purchase1.reload.zip_tax_rate).to eq(@zip_tax_rate1)
      expect(@purchase2.reload.zip_tax_rate).to eq(@zip_tax_rate1)
    end
  end

  describe "zip_code" do
    it "is set on successful if ip_address is present" do
      purchase = create(:purchase, ip_address: "199.21.86.138", purchase_state: "in_progress")
      purchase.process!
      purchase.update_balance_and_mark_successful!
      expect(purchase.reload.zip_code.length).to eq 5
    end

    it "is nil on save if ip_address is not present" do
      purchase = create(:purchase, ip_address: nil)
      purchase.save!
      expect(purchase.reload.zip_code).to be(nil)
    end

    it "is not modified if already set" do
      purchase = create(:purchase, ip_address: "8.8.8.8", zip_code: "90210")
      purchase.save!
      expect(purchase.reload.zip_code).to eq "90210"
    end
  end

  describe "#was_zipcode_check_performed" do
    before do
      @bad_card = build(:chargeable_decline)
      @good_card_without_zip_but_zip_check_would_pass = build(:chargeable, with_zip_code: false)
      @good_card_without_zip_but_zip_check_would_fail = build(:chargeable_zip_check_fails, with_zip_code: false)
      @good_card_without_zip_but_zip_check_would_unchecked = build(:chargeable_zip_check_unsupported, with_zip_code: false)
      @good_card_zip_pass = build(:chargeable, with_zip_code: true)
      @good_card_zip_fail = build(:chargeable_zip_check_fails, with_zip_code: true)
      @good_card_zip_unchecked = build(:chargeable_zip_check_unsupported, with_zip_code: true)
      @purchase = build(:purchase, purchase_state: "in_progress")
    end

    it "defaults to false" do
      expect(@purchase.was_zipcode_check_performed).to be(false)
    end

    describe "during #process!" do
      describe "with no zip code not provided" do
        describe "with good card supporting zip code check that would pass" do
          before do
            @purchase.chargeable = @good_card_without_zip_but_zip_check_would_pass
            @purchase.process!
          end
          it "processes without errors" do
            expect(@purchase.errors).to_not be_present
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end

        describe "with good card supporting zip code check that would fail" do
          before do
            @purchase.chargeable = @good_card_without_zip_but_zip_check_would_fail
            @purchase.process!
          end
          it "processes without errors" do
            expect(@purchase.errors).to_not be_present
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end

        describe "with good card not supporting zip code check" do
          before do
            @purchase.chargeable = @good_card_without_zip_but_zip_check_would_unchecked
            @purchase.process!
          end
          it "processes without errors" do
            expect(@purchase.errors).to_not be_present
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end

        describe "with bad card" do
          before do
            @purchase.chargeable = @bad_card
            @purchase.process!
          end
          it "processes and result in errors" do
            expect(@purchase.errors).to be_present
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end
      end

      describe "with zip code provided" do
        before do
          @purchase.credit_card_zipcode = @zip_code
        end

        describe "with good card supporting zip code check that would pass" do
          before do
            @purchase.chargeable = @good_card_zip_pass
            @purchase.process!
          end
          it "processes without errors" do
            expect(@purchase.errors).to_not be_present
          end
          it "is set to true" do
            expect(@purchase.was_zipcode_check_performed).to be(true)
          end
        end

        describe "with good card supporting zip code check that would fail" do
          before do
            @purchase.chargeable = @good_card_zip_fail
            @purchase.process!
          end
          it "processes and result in error" do
            expect(@purchase.errors).to be_present
            expect(@purchase.stripe_error_code).to eq "incorrect_zip"
          end
          it "is set to true" do
            expect(@purchase.was_zipcode_check_performed).to be(true)
          end
        end

        describe "with good card not supporting zip code check" do
          before do
            @purchase.chargeable = @good_card_zip_unchecked
            @purchase.process!
          end
          it "processes without errors" do
            expect(@purchase.errors).to_not be_present
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end

        describe "with bad card" do
          before do
            @purchase.chargeable = @bad_card
            @purchase.process!
          end
          it "processes and result in errors" do
            expect(@purchase.errors).to be_present
            expect(@purchase.stripe_error_code).to eq "card_declined_generic_decline"
          end
          it "is set to false" do
            expect(@purchase.was_zipcode_check_performed).to be(false)
          end
        end
      end
    end
  end
end
