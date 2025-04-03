# frozen_string_literal: true

require "spec_helper"

describe ConsumptionEvent do
  describe ".create_event!" do
    let(:url_redirect) { create(:url_redirect) }
    let(:purchase) { url_redirect.purchase }
    let(:product) { purchase.link }
    let(:product_file) { create(:product_file) }
    let(:product_folder) { create(:product_folder) }

    let(:required_params) do
      {
        event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD,
        platform: Platform::WEB,
        url_redirect_id: url_redirect.id,
        ip_address: "0.0.0.0"
      }
    end

    it "creates an event with required parameters" do
      expect { described_class.create_event!(**required_params) }.to change(ConsumptionEvent, :count).by(1)
      event = ConsumptionEvent.last
      expect(event.event_type).to eq(ConsumptionEvent::EVENT_TYPE_DOWNLOAD)
      expect(event.platform).to eq(Platform::WEB)
      expect(event.url_redirect_id).to eq(url_redirect.id)
      expect(event.ip_address).to eq("0.0.0.0")
    end

    it "raises an error if a required parameter is missing" do
      required_params.each_key do |key|
        expect { described_class.create_event!(**required_params.except(key)) }.to raise_error(KeyError)
      end
    end

    it "assigns default values to optional parameters if they are not provided" do
      event = described_class.create_event!(**required_params)
      expect(event.product_file_id).to be_nil
      expect(event.purchase_id).to be_nil
      expect(event.link_id).to be_nil
      expect(event.folder_id).to be_nil
      expect(event.consumed_at).to be_within(1.minute).of(Time.current)
    end

    it "uses provided values for optional parameters when available" do
      other_params = {
        product_file_id: product_file.id,
        purchase_id: purchase.id,
        product_id: product.id,
        folder_id: product_folder.id,
        consumed_at: 2.days.ago
      }
      event = described_class.create_event!(**required_params.merge(other_params))
      expect(event.product_file_id).to eq(product_file.id)
      expect(event.purchase_id).to eq(purchase.id)
      expect(event.link_id).to eq(product.id)
      expect(event.folder_id).to eq(product_folder.id)
      expect(event.consumed_at).to be_within(1.minute).of(2.days.ago)
    end
  end

  describe "#create" do
    before do
      @purchased_link = create(:product)
      @product_file = create(:product_file, link: @purchased_link)
      @purchase = create(:purchase, link: @purchased_link, purchase_state: :successful)
      @url_redirect = create(:url_redirect, purchase: @purchase)
    end

    it "raises error if event_type is invalid" do
      consumption_event = ConsumptionEvent.new(product_file_id: @product_file.id,
                                               url_redirect_id: @url_redirect.id, purchase_id: @purchase.id,
                                               platform: "web", consumed_at: "2015-09-09T17:26:50PDT")
      consumption_event.event_type = "invalid_event"
      consumption_event.validate
      expect(consumption_event.errors.full_messages).to include("Event type is not included in the list")
    end

    it "raises error if platform is invalid" do
      consumption_event = ConsumptionEvent.new(product_file_id: @product_file.id,
                                               url_redirect_id: @url_redirect.id, purchase_id: @purchase.id,
                                               platform: "invalid_platform", consumed_at: "2015-09-09T17:26:50PDT")
      consumption_event.event_type = "read"
      consumption_event.validate
      expect(consumption_event.errors.full_messages).to include("Platform is not included in the list")
    end
  end
end
