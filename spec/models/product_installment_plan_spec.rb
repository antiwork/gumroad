# frozen_string_literal: true

require "spec_helper"

RSpec.describe ProductInstallmentPlan do
  subject(:product_installment_plan) { build(:product_installment_plan) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:number_of_installments) }
    it { is_expected.to validate_numericality_of(:number_of_installments).only_integer.is_greater_than(1) }
  end

  describe "product eligibility" do
    context "with a recurring billing product" do
      let(:product) { create(:subscription_product) }
      let(:installment_plan) { build(:product_installment_plan, link: product) }

      it "is not eligible" do
        expect(described_class.eligible_for_product?(product)).to be false
        expect(described_class.eligibility_erorr_message_for_product(product))
          .to eq("Installment plans are not available for membership products")
        expect(installment_plan.valid?).to be false
        expect(installment_plan.errors[:base])
          .to include("Installment plans are not available for membership products")
      end
    end

    context "with a tiered membership product" do
      let(:product) { create(:membership_product) }
      let(:installment_plan) { build(:product_installment_plan, link: product) }

      it "is not eligible" do
        expect(described_class.eligible_for_product?(product)).to be false
        expect(described_class.eligibility_erorr_message_for_product(product))
          .to eq("Installment plans are not available for membership products")
        expect(installment_plan.valid?).to be false
        expect(installment_plan.errors[:base])
          .to include("Installment plans are not available for membership products")
      end
    end

    context "with a preorder product" do
      let(:product) { create(:product, is_in_preorder_state: true) }
      let(:installment_plan) { build(:product_installment_plan, link: product) }

      it "is not eligible" do
        expect(described_class.eligible_for_product?(product)).to be false
        expect(described_class.eligibility_erorr_message_for_product(product))
          .to eq("Installment plans are not available for pre-order products")
        expect(installment_plan.valid?).to be false
        expect(installment_plan.errors[:base])
          .to include("Installment plans are not available for pre-order products")
      end
    end

    context "with a physical product" do
      let(:product) { create(:physical_product) }
      let(:installment_plan) { build(:product_installment_plan, link: product) }

      it "is not eligible" do
        expect(described_class.eligible_for_product?(product)).to be false
        expect(described_class.eligibility_erorr_message_for_product(product))
          .to eq("Installment plans are not available for this product type")
        expect(installment_plan.valid?).to be false
        expect(installment_plan.errors[:base])
          .to include("Installment plans are not available for this product type")
      end
    end

    context "with a bundle product" do
      let(:seller) { create(:user, :eligible_for_service_products) }

      let(:bundle) { create(:product, :bundle, user: seller, price_cents: 1000) }
      let(:course_product) { create(:product, native_type: Link::NATIVE_TYPE_COURSE, user: seller) }
      let(:physical_product) { create(:product, native_type: Link::NATIVE_TYPE_PHYSICAL, user: seller) }

      let(:installment_plan) { build(:product_installment_plan, link: bundle) }

      context "when all products in the bundle are eligible" do
        before do
          bundle.bundle_products << build(:bundle_product, bundle: bundle, product: course_product)
        end

        it "is valid" do
          expect(installment_plan.valid?).to be true
        end
      end

      context "when some products in the bundle are not eligible" do
        before do
          bundle.bundle_products << build(:bundle_product, bundle: bundle, product: course_product)
          bundle.bundle_products << build(:bundle_product, bundle: bundle, product: physical_product)
        end

        it "is not valid" do
          expect(installment_plan.valid?).to be false
          expect(installment_plan.errors[:base])
            .to include("Installment plan is not available for the bundled product: #{physical_product.name}")
        end
      end

      context "when the bundle has no products" do
        it "is valid" do
          expect(installment_plan.valid?).to be true
        end
      end
    end

    context "with eligible product types" do
      let(:digital_product) { create(:product, native_type: Link::NATIVE_TYPE_DIGITAL, price_cents: 1000) }
      let(:course_product) { create(:product, native_type: Link::NATIVE_TYPE_COURSE, price_cents: 1000) }
      let(:ebook_product) { create(:product, native_type: Link::NATIVE_TYPE_EBOOK, price_cents: 1000) }
      let(:call_product) { create(:call_product, price_cents: 1000) }

      [
        :digital_product,
        :course_product,
        :ebook_product,
        :call_product,
      ].each do |product_name|
        context "with #{product_name}" do
          let(:product) { public_send(product_name) }
          let(:installment_plan) { build(:product_installment_plan, link: product) }

          it "is eligible" do
            expect(described_class.eligible_for_product?(product)).to be true
            expect(described_class.eligibility_erorr_message_for_product(product)).to be_nil
            expect(installment_plan.valid?).to be true
          end
        end
      end
    end
  end

  describe "installment payment price" do
    let(:product) { create(:product, price_cents: 99 * 2, price_currency_type: "usd") }
    let(:installment_plan) { build(:product_installment_plan, link: product, number_of_installments: 2) }

    it "must be at least the minimum price for each installment" do
      installment_plan.number_of_installments = 2
      expect(installment_plan).to be_valid

      installment_plan.number_of_installments = 0
      expect(installment_plan).not_to be_valid

      installment_plan.number_of_installments = 3
      expect(installment_plan).not_to be_valid
      expect(installment_plan.errors[:base])
        .to include("The minimum price for each installment must be at least 0.99 USD.")
    end

    it "cannot be pwyw" do
      product.update!(customizable_price: true)

      expect(installment_plan).not_to be_valid
      expect(installment_plan.errors[:base])
        .to include('Installment plans are not available for "pay what you want" pricing')
    end
  end

  describe "#calculate_installment_payment_price_cents" do
    let(:installment_plan) { build(:product_installment_plan, number_of_installments: 3) }

    it "splits price evenly when divisible by number of installments" do
      result = installment_plan.calculate_installment_payment_price_cents(3000)
      expect(result).to eq([1000, 1000, 1000])
    end

    it "adds remainder to first installment when price not evenly divisible" do
      result = installment_plan.calculate_installment_payment_price_cents(3002)
      expect(result).to eq([1002, 1000, 1000])
    end
  end

  describe "#destroy_if_no_payment_options!" do
    let(:product) { create(:product, price_cents: 99 * 2, price_currency_type: "usd") }
    let(:installment_plan) { build(:product_installment_plan, link: product, number_of_installments: 2) }

    context "with no payment options" do
      it "destroys the installment plan" do
        installment_plan.destroy_if_no_payment_options!

        expect { installment_plan.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "with existing payment options" do
      before do
        create(:payment_option, installment_plan:)
      end

      it "soft deletes the installment plan even if product is no longer eligible for installment plans" do
        product.update_column(:price_cents, 0)

        expect { installment_plan.destroy_if_no_payment_options! }
          .to change(installment_plan, :deleted_at).from(nil)
      end

      it "cannot be destroyed" do
        expect { installment_plan.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
      end
    end
  end
end
