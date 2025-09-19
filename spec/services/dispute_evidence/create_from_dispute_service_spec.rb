# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::CreateFromDisputeService, :vcr, :versioning do
  let(:product) do
    travel_to 1.hour.ago do
      create(
        :physical_product,
        name: "Sample product title at purchase time"
      )
    end
  end

  let(:variant) { create(:variant, name: "Platinum", variant_category: create(:variant_category, link: product)) }

  let!(:disputed_purchase) do
    create(
      :disputed_purchase,
      email: "customer@example.com",
      full_name: "John Example",
      street_address: "123 Sample St",
      city: "San Francisco",
      state: "CA",
      country: "United States",
      zip_code: "12343",
      ip_state: "California",
      ip_country: "United States",
      credit_card_zipcode: "1234",
      link: product,
      url_redirect: create(:url_redirect),
      quantity: 2,
      variant_attributes: [variant]
    )
  end

  let!(:shipment) do
    create(
      :shipment,
      carrier: "UPS",
      tracking_number: "123456",
      purchase: disputed_purchase,
      ship_state: "shipped",
      shipped_at: DateTime.parse("2023-02-10 14:55:32")
    )
  end

  let!(:sample_image) { File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg")) }

  before do
    create(:dispute_formalized, purchase: disputed_purchase)

    travel_to 1.hour.from_now do
      product.update!(
        name: "New product title",
        description: "New product description"
      )
    end
  end

  it "creates a dispute evidence" do
    allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(disputed_purchase).and_return(sample_image)
    allow(DisputeEvidence::GenerateUncategorizedTextService).to(
      receive(:perform).with(disputed_purchase).and_return("Sample uncategorized text")
    )
    allow(DisputeEvidence::GenerateAccessActivityLogsService).to(
      receive(:perform).with(disputed_purchase).and_return("Sample activity logs")
    )
    dispute_evidence = DisputeEvidence.create_from_dispute!(disputed_purchase.dispute)

    expect(dispute_evidence.dispute).to eq(disputed_purchase.dispute)
    expect(dispute_evidence.purchased_at).to eq(disputed_purchase.created_at)
    expect(dispute_evidence.customer_purchase_ip).to eq(disputed_purchase.ip_address)
    expect(dispute_evidence.customer_email).to eq(disputed_purchase.email)
    expect(dispute_evidence.customer_name).to eq(disputed_purchase.full_name)
    expect(dispute_evidence.billing_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
    expect(dispute_evidence.shipping_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
    expect(dispute_evidence.shipped_at).to eq(shipment.shipped_at)
    expect(dispute_evidence.shipping_carrier).to eq("UPS")
    expect(dispute_evidence.shipping_tracking_number).to eq(shipment.tracking_number)

    expected_product_description = \
      "Product name: Sample product title at purchase time\n" +
      "Product as seen when purchased: #{Rails.application.routes.url_helpers.purchase_product_url(disputed_purchase.external_id, host: DOMAIN, protocol: PROTOCOL)}\n" +
      "Product type: physical product\n" +
      "Product variant: Platinum\n" +
      "Quantity purchased: 2\n" +
      "Receipt: #{Rails.application.routes.url_helpers.receipt_purchase_url(disputed_purchase.external_id, email: disputed_purchase.email, host: DOMAIN, protocol: PROTOCOL)}\n" +
      "Live product: #{disputed_purchase.link.long_url}"
    expect(dispute_evidence.product_description).to eq(expected_product_description)
    expect(dispute_evidence.uncategorized_text).to eq("Sample uncategorized text")
    expect(dispute_evidence.receipt_image).to be_attached
    expect(dispute_evidence.refund_policy_image).not_to be_attached
    expect(dispute_evidence.refund_policy_disclosure).to be_nil
    expect(dispute_evidence.cancellation_policy_image).not_to be_attached
    expect(dispute_evidence.cancellation_policy_disclosure).to be_nil
    expect(dispute_evidence.access_activity_log).to eq("Sample activity logs")
  end

  context "when dispute is on a combined charge" do
    let(:purchase) do
      create(
        :purchase,
        total_transaction_cents: 20_00,
        chargeback_date: Date.today,
        email: "customer@example.com",
        full_name: "John Example",
        street_address: "123 Sample St",
        city: "San Francisco",
        state: "CA",
        country: "United States",
        zip_code: "12343",
        ip_state: "California",
        ip_country: "United States",
        credit_card_zipcode: "1234",
        link: product,
        url_redirect: create(:url_redirect),
        quantity: 2,
        variant_attributes: [variant]
      )
    end

    let(:charge) do
      charge = create(:charge)
      charge.purchases << create(:purchase, total_transaction_cents: 10_00, email: "customer@example.com")
      charge.purchases << purchase
      charge.purchases << create(:purchase, total_transaction_cents: 5_00, email: "customer@example.com")
      charge
    end

    let(:shipment) do
      create(
        :shipment,
        carrier: "UPS",
        tracking_number: "123456",
        purchase:,
        ship_state: "shipped",
        shipped_at: DateTime.parse("2023-02-10 14:55:32")
      )
    end

    let(:dispute) { create(:dispute_on_charge, charge:) }

    before do
      expect(charge.purchase_for_dispute_evidence).to eq purchase

      allow(DisputeEvidence::GenerateUncategorizedTextService).to(
        receive(:perform).with(purchase).and_return("Sample uncategorized text")
      )
      allow(DisputeEvidence::GenerateAccessActivityLogsService).to(
        receive(:perform).with(purchase).and_return("Sample activity logs")
      )
      allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(purchase).and_return(sample_image)
    end

    it "creates a dispute evidence" do
      dispute_evidence = DisputeEvidence.create_from_dispute!(dispute)

      expect(dispute_evidence.dispute).to eq(charge.dispute)
      expect(dispute_evidence.purchased_at).to eq(purchase.created_at)
      expect(dispute_evidence.customer_purchase_ip).to eq(purchase.ip_address)
      expect(dispute_evidence.customer_email).to eq(purchase.email)
      expect(dispute_evidence.customer_name).to eq(purchase.full_name)
      expect(dispute_evidence.billing_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
      expect(dispute_evidence.shipping_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
      expect(dispute_evidence.shipped_at).to eq(shipment.shipped_at)
      expect(dispute_evidence.shipping_carrier).to eq("UPS")
      expect(dispute_evidence.shipping_tracking_number).to eq(shipment.tracking_number)

      product_description = \
      "Product name: Sample product title at purchase time\n" +
          "Product as seen when purchased: #{Rails.application.routes.url_helpers.purchase_product_url(purchase.external_id, host: DOMAIN, protocol: PROTOCOL)}\n" +
          "Product type: physical product\n" +
          "Product variant: Platinum\n" +
          "Quantity purchased: 2\n" +
          "Receipt: #{Rails.application.routes.url_helpers.receipt_purchase_url(purchase.external_id, email: purchase.email, host: DOMAIN, protocol: PROTOCOL)}\n" +
          "Live product: #{purchase.link.long_url}"
      expect(dispute_evidence.product_description).to eq(product_description)

      expect(dispute_evidence.uncategorized_text).to eq("Sample uncategorized text")

      expect(dispute_evidence.receipt_image).to be_attached
      expect(dispute_evidence.refund_policy_image).not_to be_attached
      expect(dispute_evidence.refund_policy_disclosure).to be_nil
      expect(dispute_evidence.cancellation_policy_image).not_to be_attached
      expect(dispute_evidence.cancellation_policy_disclosure).to be_nil
      expect(dispute_evidence.access_activity_log).to eq("Sample activity logs")
    end
  end

  context "when the purchase has a refund policy" do
    let(:url) do
      Rails.application.routes.url_helpers.purchase_product_url(
        disputed_purchase.external_id,
        host: DOMAIN,
        protocol: PROTOCOL,
        anchor: nil,
      )
    end
    let(:sample_image) { File.read(Rails.root.join("spec", "support", "fixtures", "test-small.jpg")) }

    before do
      disputed_purchase.create_purchase_refund_policy!(
        title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
        max_refund_period_in_days: 30,
        fine_print: "This is the fine print."
      )

      allow(DisputeEvidence::GenerateRefundPolicyImageService)
        .to receive(:perform).with(url:, mobile_purchase: false, open_fine_print_modal: false, max_size_allowed: anything)
        .and_return sample_image
      allow(DisputeEvidence::GenerateUncategorizedTextService).to(
        receive(:perform).with(disputed_purchase).and_return("Sample uncategorized text")
      )
      allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(disputed_purchase).and_return(sample_image)
    end

    it "attaches refund policy image" do
      dispute_evidence = DisputeEvidence.create_from_dispute!(disputed_purchase.dispute)

      expect(dispute_evidence.refund_policy_image).to be_attached
    end

    context "when the refund policy image is too big" do
      before do
        allow(DisputeEvidence::GenerateRefundPolicyImageService).to receive(:perform).and_raise(DisputeEvidence::GenerateRefundPolicyImageService::ImageTooLargeError)
      end

      it "doesn't attach refund policy image" do
        dispute_evidence = DisputeEvidence.create_from_dispute!(disputed_purchase.dispute)

        expect(dispute_evidence.refund_policy_image).not_to be_attached
      end
    end

    context "when there is a view event before the purchase" do
      let!(:event) do
        disputed_purchase.events.create!(
          event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
          link_id: disputed_purchase.link_id,
          browser_guid: disputed_purchase.browser_guid,
          created_at: disputed_purchase.created_at - 1.second
        )
      end
      let(:url) do
        Rails.application.routes.url_helpers.purchase_product_url(
          disputed_purchase.external_id,
          host: DOMAIN,
          protocol: PROTOCOL,
          anchor: "refund-policy"
        )
      end
      let(:open_fine_print_modal) { true }

      before do
        allow(DisputeEvidence::GenerateRefundPolicyImageService)
          .to receive(:perform).with(url:, mobile_purchase: false, open_fine_print_modal:, max_size_allowed: anything)
          .and_return sample_image
      end

      it "generates refund policy disclosure" do
        dispute_evidence = DisputeEvidence.create_from_dispute!(disputed_purchase.dispute)

        expect(dispute_evidence.refund_policy_disclosure).to eq(
        "The refund policy modal has been viewed by the customer 1 time before the purchase was made at #{disputed_purchase.created_at}.\n" \
        "Timestamp information of the view: #{event.created_at}\n\n" \
        "Internal browser GUID for reference: #{disputed_purchase.browser_guid}"
        )
      end
    end
  end

  context "#find_refund_policy_fine_print_view_events" do
    let(:service_instance) { described_class.new(disputed_purchase.dispute) }
    let(:events) { service_instance.send(:find_refund_policy_fine_print_view_events, disputed_purchase) }

    before do
      allow(DisputeEvidence::GenerateUncategorizedTextService).to(
        receive(:perform).with(disputed_purchase).and_return("Sample uncategorized text")
      )
      allow(DisputeEvidence::GenerateReceiptImageService).to receive(:perform).with(disputed_purchase).and_return(sample_image)
    end

    context "when there are no events" do
      it "returns empty array" do
        expect(events.count).to eq(0)
      end
    end

    context "when there is one eligible event" do
      let!(:event) do
        disputed_purchase.events.create!(
          event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
          link_id: disputed_purchase.link_id,
          browser_guid: disputed_purchase.browser_guid,
          created_at: disputed_purchase.created_at - 1.second
        )
      end

      it "returns an array with the event" do
        expect(events).to eq([event])
      end
    end

    context "when the event belongs to a different product" do
      let(:another_purchase) { create(:purchase) }
      let!(:event) do
        another_purchase.events.create!(
          event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
          link_id: another_purchase.link_id,
          browser_guid: another_purchase.browser_guid,
          created_at: another_purchase.created_at + 1.second
        )
      end

      it "doesn't include the event" do
        expect(events.count).to eq(0)
      end
    end

    context "when the event has a different browser guid" do
      let!(:event) do
        disputed_purchase.events.create!(
          event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
          link_id: disputed_purchase.link_id,
          browser_guid: "other_guid",
          created_at: disputed_purchase.created_at - 1.second
        )
      end

      it "doesn't include the event" do
        expect(events.count).to eq(0)
      end
    end

    context "when the view event is done after the purchase" do
      let!(:event) do
        disputed_purchase.events.create!(
          event_name: Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW,
          link_id: disputed_purchase.link_id,
          browser_guid: disputed_purchase.browser_guid,
          created_at: disputed_purchase.created_at + 1.second
        )
      end

      it "doesn't include the event" do
        expect(events.count).to eq(0)
      end
    end
  end

  describe "#mobile_purchase?" do
    let(:service_instance) { described_class.new(disputed_purchase.dispute) }

    context "when purchase.is_mobile is false" do
      before { disputed_purchase.update!(is_mobile: false) }

      it "returns false" do
        expect(service_instance.send(:mobile_purchase?)).to eq(false)
      end
    end

    context "when purchase.is_mobile is empty" do
      before { disputed_purchase.update!(is_mobile: "") }

      it "returns false" do
        expect(service_instance.send(:mobile_purchase?)).to eq(false)
      end
    end

    context "when purchase.is_mobile is 1" do
      before { disputed_purchase.update!(is_mobile: 1) }

      it "returns true" do
        expect(service_instance.send(:mobile_purchase?)).to eq(true)
      end
    end
  end
end
