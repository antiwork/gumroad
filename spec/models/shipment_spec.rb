# frozen_string_literal: true

require "spec_helper"

describe Shipment do
  describe "#shipped?" do
    it "returns false is shipped_at is nil" do
      expect(create(:shipment).shipped?).to be(false)
    end

    it "returns true is shipped_at is present" do
      expect(create(:shipment, shipped_at: 1.day.ago).shipped?).to be(true)
    end
  end

  describe "#mark_as_shipped" do
    it "marks a shipment as shipped" do
      shipment = create(:shipment)
      shipment.mark_shipped
      expect(shipment.shipped?).to be(true)
    end
  end

  describe "notify_sender_of_sale" do
    before do
      user = create(:user)
      link = create(:physical_product, user:)
      purchase = create(:physical_purchase, link:)
      @shipment = create(:shipment, purchase:)
    end

    it "sends sender email of receiver sale" do
      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerLowPriorityMailer).to receive(:order_shipped).and_return(mail_double)
      @shipment.mark_shipped
    end
  end

  describe "#calculated_tracking_url" do
    before do
      user = create(:user)
      link = create(:physical_product, user:)
      purchase = create(:physical_purchase, link:)
      @shipment = create(:shipment, purchase:, tracking_number: "1234567890", carrier: "USPS")
    end

    it "returns the tracking_url if present" do
      @shipment.update(tracking_url: "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890")
      expect(@shipment.calculated_tracking_url).to eq("https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890")
    end

    it "returns the right url based on carrier and tracking_number when tracking_url is not present" do
      @shipment.update(carrier: "USPS", tracking_number: "1234567890")
      expect(@shipment.calculated_tracking_url).to eq("https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=1234567890")

      @shipment.update(carrier: "UPS")
      expect(@shipment.calculated_tracking_url).to eq("http://wwwapps.ups.com/WebTracking/processInputRequest?TypeOfInquiryNumber=T&InquiryNumber1=1234567890")

      @shipment.update(carrier: "FedEx")
      expect(@shipment.calculated_tracking_url).to eq("http://www.fedex.com/Tracking?language=english&cntry_code=us&tracknumbers=1234567890")

      @shipment.update(carrier: "DHL")
      expect(@shipment.calculated_tracking_url).to eq("http://www.dhl.com/content/g0/en/express/tracking.shtml?brand=DHL&AWB=1234567890")

      @shipment.update(carrier: "OnTrac")
      expect(@shipment.calculated_tracking_url).to eq("http://www.ontrac.com/trackres.asp?tracking_number=1234567890")

      @shipment.update(carrier: "Canada Post")
      expect(@shipment.calculated_tracking_url).to eq("https://www.canadapost.ca/cpotools/apps/track/personal/findByTrackNumber?LOCALE=en&trackingNumber=1234567890")
    end

    it "does not return anything if no tracking_url and no carrier" do
      @shipment.update(carrier: nil)
      expect(@shipment.calculated_tracking_url).to eq(nil)
    end

    it "does not return anything if no tracking_url and no tracking number" do
      @shipment.update(tracking_number: nil)
      expect(@shipment.calculated_tracking_url).to eq(nil)
    end

    it "does not return anything if no tracking_url and unrecognized carrier" do
      @shipment.update(carrier: "AnishOnTime")
      expect(@shipment.calculated_tracking_url).to eq(nil)
    end
  end

  describe "#carrier_and_tracking_number_from_url" do
    # The shape production actually stores: a tracking URL and nothing else.
    let(:shipment) { create(:shipment, carrier: nil, tracking_number: nil) }

    it "recovers the carrier and number for every mapped carrier" do
      Shipment::CARRIER_TRACKING_URL_MAPPING.each do |carrier, prefix|
        shipment.update!(tracking_url: "#{prefix}1Z999AA10123456784")
        expect(shipment.carrier_and_tracking_number_from_url).to eq([carrier, "1Z999AA10123456784"]),
                                                                 "expected #{carrier} to round-trip from #{prefix}"
      end
    end

    it "matches regardless of the URL's scheme" do
      # The stored prefixes are http for carriers that now redirect to https, and a seller pasting
      # from the carrier's own site gets the https form.
      shipment.update!(tracking_url: "https://wwwapps.ups.com/WebTracking/processInputRequest?TypeOfInquiryNumber=T&InquiryNumber1=1Z999")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["UPS", "1Z999"])
    end

    it "returns nothing for a URL that is not a known carrier's tracking form" do
      shipment.update!(tracking_url: "https://track.aftership.com/1Z999AA10123456784")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing when the remainder is not a bare tracking number" do
      # Extra query parameters mean we cannot tell where the number ends, and a wrong number
      # submitted as evidence is worse than none.
      shipment.update!(tracking_url: "#{Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]}1Z999&tRef=fullpage")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing when no tracking URL was supplied" do
      expect(create(:shipment, carrier: nil, tracking_number: nil, tracking_url: nil)
               .carrier_and_tracking_number_from_url).to be_nil
    end
  end
end
