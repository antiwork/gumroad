# frozen_string_literal: true

describe InvoicePresenter do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) do
    create(
      :purchase,
      link: product,
      seller:,
      price_cents: 1_499,
      created_at: DateTime.parse("January 1, 2023")
    )
  end
  let(:address_fields) do
    {
      full_name: "Customer Name",
      street_address: "1234 Main St",
      city: "City",
      state: "State",
      zip_code: "12345",
      country: "United States"
    }
  end
  let(:presenter) { described_class.new(chargeable) }

  describe "For Purchase" do
    let(:chargeable) { purchase }

    describe "#supplier_info" do
      it "returns a SupplierInfo object" do
        expect(presenter.supplier_info).to be_a(InvoicePresenter::SupplierInfo)
        expect(presenter.supplier_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#seller_info" do
      it "returns a SellerInfo object" do
        expect(presenter.seller_info).to be_a(InvoicePresenter::SellerInfo)
        expect(presenter.seller_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#order_info" do
      let(:additional_notes) { "Additional notes" }
      let(:business_vat_id) { "VAT12345" }
      let(:presenter) { described_class.new(chargeable, address_fields:, additional_notes:, business_vat_id:) }

      it "returns an OrderInfo object" do
        expect(presenter.order_info).to be_a(InvoicePresenter::OrderInfo)
        expect(presenter.order_info.send(:chargeable)).to eq(chargeable)
        expect(presenter.order_info.send(:address_fields)).to eq(address_fields)
        expect(presenter.order_info.send(:additional_notes)).to eq(additional_notes)
        expect(presenter.order_info.send(:business_vat_id)).to eq(business_vat_id)
      end

      it "includes sales tax breakdown for Canada", :vcr do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "AB", ip_country: "Canada")
        purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "BC", ip_country: "Canada")
        purchase3 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "QC", ip_country: "Canada")

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        presenter = described_class.new(purchase1.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(purchase2.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).to include({ label: "PST", value: "$7" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).to include({ label: "PST", value: "$7" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(purchase3.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.form_attributes).to include({ label: "QST", value: "$9.98" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "QST", value: "$9.98" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))
      end
    end

    describe "#invoice_generation_form_data_props" do
      it "returns the form data" do
        props = presenter.invoice_generation_form_data_props

        expect(props).to match(
          purchase_id: chargeable.external_id_for_invoice,
          address_fields: be_a(Hash),
          email: purchase.email,
          vat_id: "",
          additional_notes: "",
        )
      end
    end

    describe "#invoice_generation_form_metadata_props" do
      it "returns the form metadata" do
        props = presenter.invoice_generation_form_metadata_props

        expect(props).to match(
          heading: be_a(String),
          display_vat_id: be_in([true, false]),
          vat_id_label: be_a(String),
          supplier_info: be_a(Hash),
          seller_info: be_a(Hash),
          order_info: be_a(Hash),
          countries: be_a(Hash),
        )

        expect(props[:countries]).to eq(Compliance::Countries.for_select.to_h)
      end
    end
  end

  describe "For Charge" do
    let(:charge) { create(:charge, purchases: [purchase], order: create(:order, purchaser: purchase.purchaser, purchases: [purchase])) }
    let(:chargeable) { charge }

    describe "#supplier_info" do
      it "returns a SupplierInfo object" do
        expect(presenter.supplier_info).to be_a(InvoicePresenter::SupplierInfo)
        expect(presenter.supplier_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#seller_info" do
      it "returns a SellerInfo object" do
        expect(presenter.seller_info).to be_a(InvoicePresenter::SellerInfo)
        expect(presenter.seller_info.send(:chargeable)).to eq(chargeable)
      end
    end

    describe "#order_info" do
      let(:additional_notes) { "Additional notes" }
      let(:business_vat_id) { "VAT12345" }
      let(:presenter) { described_class.new(chargeable, address_fields:, additional_notes:, business_vat_id:) }

      it "returns an OrderInfo object" do
        expect(presenter.order_info).to be_a(InvoicePresenter::OrderInfo)
        expect(presenter.order_info.send(:chargeable)).to eq(chargeable)
        expect(presenter.order_info.send(:address_fields)).to eq(address_fields)
        expect(presenter.order_info.send(:additional_notes)).to eq(additional_notes)
        expect(presenter.order_info.send(:business_vat_id)).to eq(business_vat_id)
      end

      it "includes sales tax breakdown for Canada", :vcr do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "AB", ip_country: "Canada")
        charge1 = create(:charge)
        charge1.purchases << purchase1
        purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "BC", ip_country: "Canada")
        charge2 = create(:charge)
        charge2.purchases << purchase2
        purchase3 = create(:purchase_in_progress, link: product, was_product_recommended: true, recommended_by: "search", country: "Canada", state: "QC", ip_country: "Canada")
        charge3 = create(:charge)
        charge3.purchases << purchase3
        order = create(:order)
        order.charges << [charge1, charge2, charge3]
        order.purchases << [purchase1, purchase2, purchase3]

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end

        presenter = described_class.new(charge1.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(charge2.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).to include({ label: "PST", value: "$7" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).to include({ label: "PST", value: "$7" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "QST"))
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))

        presenter = described_class.new(charge3.reload, address_fields:, additional_notes:, business_vat_id: nil)
        expect(presenter.order_info.form_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.form_attributes).to include({ label: "QST", value: "$9.98" })
        expect(presenter.order_info.form_attributes).not_to include(hash_including(label: "Sales tax"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "GST/HST", value: "$5" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "PST"))
        expect(presenter.order_info.pdf_attributes).to include({ label: "QST", value: "$9.98" })
        expect(presenter.order_info.pdf_attributes).not_to include(hash_including(label: "Sales tax"))
      end
    end

    describe "#invoice_generation_form_data_props" do
      it "returns the form data" do
        props = presenter.invoice_generation_form_data_props

        expect(props).to match(
          purchase_id: chargeable.external_id_for_invoice,
          address_fields: be_a(Hash),
          email: purchase.email,
          vat_id: "",
          additional_notes: "",
        )
      end
    end

    describe "#invoice_generation_form_metadata_props" do
      it "returns the form metadata" do
        props = presenter.invoice_generation_form_metadata_props

        expect(props).to match(
          heading: be_a(String),
          display_vat_id: be_in([true, false]),
          vat_id_label: be_a(String),
          supplier_info: be_a(Hash),
          seller_info: be_a(Hash),
          order_info: be_a(Hash),
          countries: be_a(Hash),
        )

        expect(props[:countries]).to eq(Compliance::Countries.for_select.to_h)
      end
    end
  end
end
