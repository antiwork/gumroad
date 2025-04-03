# frozen_string_literal: true

require "spec_helper"

shared_examples_for "common customer recipient filter validation behavior" do |audience_type:|
  context "when #{audience_type} #{described_class.to_s.downcase}" do
    context "when no param filters are set" do
      let(:params) do
        {
          bought_products: [],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          affiliate_products: [],
          paid_more_than: "",
          paid_less_than: "",
          created_after: "",
          created_before: "",
          bought_from: ""
        }
      end

      it "returns true" do
        is_expected.to eq(true)
      end
    end

    context "when valid param filters are set" do
      let(:params) do
        {
          bought_products: "B",
          bought_variants: ["123"],
          not_bought_products: "N",
          not_bought_variants: "NV",
          affiliate_products: ["A"],
          paid_more_than: "5",
          paid_less_than: "10",
          created_after: "Sun Feb 28 2021",
          created_before: "Mon Mar 1 2021",
          bought_from: "United States"
        }
      end

      it "sets the filter attributes" do
        add_and_validate_filters
        expect(filterable_object.bought_products).to contain_exactly("B")
        expect(filterable_object.bought_variants).to contain_exactly("123")
        expect(filterable_object.not_bought_products).to contain_exactly("N")
        expect(filterable_object.not_bought_variants).to contain_exactly("NV")
        expect(filterable_object.affiliate_products).to contain_exactly("A")
        expect(filterable_object.paid_more_than_cents).to eq(500)
        expect(filterable_object.paid_less_than_cents).to eq(1000)
        expect(filterable_object.created_after).to be_present
        expect(filterable_object.created_before).to be_present
        expect(filterable_object.bought_from).to eq("United States")
      end

      context "when paid_more_than_cents and paid_less_than_cents are given" do
        let(:params) do
          {
            paid_more_than_cents: 1200,
            paid_less_than_cents: 1400,
            paid_more_than: nil,
            paid_less_than: nil
          }
        end

        it "sets the filter attributes" do
          add_and_validate_filters
          expect(filterable_object.paid_more_than_cents).to eq(1200)
          expect(filterable_object.paid_less_than_cents).to eq(1400)
        end
      end
    end

    context "when paid more is greater than paid less" do
      let(:params) do
        {
          bought_products: [product.unique_permalink],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          affiliate_products: [],
          paid_more_than: "100",
          paid_less_than: "99",
          created_after: "",
          created_before: "",
          bought_from: ""
        }
      end

      it "returns false and adds a base error to the object" do
        is_expected.to eq(false)
        expect(filterable_object.reload.errors[:base]).to contain_exactly("Please enter valid paid more than and paid less than values.")
      end

      context "when paid_more_than_cents and paid_less_than_cents are given" do
        let(:params) do
          {
            paid_more_than_cents: 1500,
            paid_less_than_cents: 1000,
            paid_more_than: nil,
            paid_less_than: nil
          }
        end

        it "returns false and adds a base error to the object" do
          is_expected.to eq(false)
          expect(filterable_object.reload.errors[:base]).to contain_exactly("Please enter valid paid more than and paid less than values.")
        end
      end
    end

    context "when created_after is greater than created_before" do
      let(:params) do
        {
          affiliate_products: [],
          bought_products: [],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          paid_more_than: "",
          paid_less_than: "",
          created_after: "Mon Mar 1 2021",
          created_before: "Sun Feb 28 2021",
          bought_from: ""
        }
      end

      it "returns false and adds a base error to the object" do
        is_expected.to eq(false)
        expect(filterable_object.reload.errors[:base]).to contain_exactly("Please enter valid before and after dates.")
      end
    end
  end
end

shared_examples_for "common non-customer recipient filter validation behavior" do |audience_type:|
  context "when #{audience_type} #{described_class.to_s.downcase}" do
    context "when no param filters are set" do
      let(:params) do
        {
          affiliate_products: [],
          bought_products: [],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          paid_more_than: "",
          paid_less_than: "",
          created_after: "",
          created_before: "",
          bought_from: ""
        }
      end

      it "returns true" do
        is_expected.to eq(true)
      end
    end

    context "when paid more is greater than paid less" do
      let(:params) do
        {
          affiliate_products: [],
          bought_products: [product.unique_permalink],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          paid_more_than: "100",
          paid_less_than: "99",
          created_after: "",
          created_before: "",
          bought_from: ""
        }
      end

      it "returns true and does not add a base error to the object" do
        is_expected.to eq(true)
        expect(filterable_object.reload.errors.any?).to eq(false)
      end
    end

    context "when created_after is greater than created_before" do
      let(:params) do
        {
          affiliate_products: [],
          bought_products: [],
          bought_variants: [],
          not_bought_products: [],
          not_bought_variants: [],
          paid_more_than: "",
          paid_less_than: "",
          created_after: "Mon Mar 1 2021",
          created_before: "Sun Feb 28 2021",
          bought_from: ""
        }
      end

      it "returns false and adds a base error to the object" do
        is_expected.to eq(false)
        expect(filterable_object.reload.errors[:base]).to contain_exactly("Please enter valid before and after dates.")
      end
    end

    context "when valid param filters are set" do
      let(:params) do
        {
          bought_products: "B",
          bought_variants: ["123"],
          not_bought_products: "N",
          not_bought_variants: "NV",
          affiliate_products: ["A"],
          paid_more_than: "5",
          paid_less_than: "10",
          created_after: "Sun Feb 28 2021",
          created_before: "Mon Mar 1 2021",
          bought_from: "United States"
        }
      end

      it "sets the filter attributes" do
        add_and_validate_filters

        # We don't store bought filters when targeting everyone
        if audience_type == "audience"
          expect(filterable_object.affiliate_products).to eq(nil)
          expect(filterable_object.bought_products).to eq(nil)
          expect(filterable_object.bought_variants).to eq(nil)
        else
          expect(filterable_object.affiliate_products).to contain_exactly("A")
          expect(filterable_object.bought_products).to contain_exactly("B")
          expect(filterable_object.bought_variants).to contain_exactly("123")
        end

        expect(filterable_object.not_bought_products).to contain_exactly("N")
        expect(filterable_object.not_bought_variants).to contain_exactly("NV")
        expect(filterable_object.paid_more_than_cents).to eq(nil)
        expect(filterable_object.paid_less_than_cents).to eq(nil)
        expect(filterable_object.created_after).to be_present
        expect(filterable_object.created_before).to be_present
        expect(filterable_object.bought_from).to eq(nil)
      end
    end
  end
end
