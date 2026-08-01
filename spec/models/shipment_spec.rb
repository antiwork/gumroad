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

    # One number each carrier really issues, so the round-trip is not asserted with a value the
    # carrier's own format would reject.
    real_numbers = {
      "USPS" => "9400111899223197428490",
      "UPS" => "1Z999AA10123456784",
      "FedEx" => "123456789012",
      "DHL" => "1234567890",
      "DHL Global Mail" => "94748100000000000000",
      "OnTrac" => "C10999911111111",
      "Canada Post" => "1234567890123456"
    }.freeze

    it "recovers the carrier and number for every mapped carrier" do
      Shipment::CARRIER_TRACKING_URL_MAPPING.each do |carrier, prefix|
        number = real_numbers.fetch(carrier)
        shipment.update!(tracking_url: "#{prefix}#{number}")
        expect(shipment.carrier_and_tracking_number_from_url).to eq([carrier, number]),
                                                                 "expected #{carrier} to round-trip from #{prefix}"
      end
    end

    it "knows a format for every mapped carrier" do
      # A carrier present in the URL mapping but absent from the format mapping derives nothing at
      # all — silently, and only for that carrier. Adding a carrier means adding both.
      expect(Shipment::CARRIER_TRACKING_NUMBER_FORMAT.keys)
        .to match_array(Shipment::CARRIER_TRACKING_URL_MAPPING.keys)
    end

    it "rejects a number that reaches a carrier's form but is not a format that carrier issues" do
      # Ten digits is a DHL waybill, not a USPS number, and Stripe takes one submission.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      ["1234567890", "1Z999AA10123456784", "123456789012345678901"].each do |number|
        shipment.update!(tracking_url: "#{usps}#{number}")
        expect(shipment.carrier_and_tracking_number_from_url).to be_nil,
                                                                 "expected USPS to reject #{number}"
      end

      shipment.update!(tracking_url: "#{Shipment::CARRIER_TRACKING_URL_MAPPING['DHL']}1234567890")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["DHL", "1234567890"])
    end

    it "accepts the USPS international form as well as the domestic one" do
      # S10 (two letters, nine digits, two letters) is a real USPS number and is not 20-plus digits,
      # so a digits-only format would drop it.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      shipment.update!(tracking_url: "#{usps}LZ123456789US")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["USPS", "LZ123456789US"])
    end

    it "matches regardless of the URL's scheme" do
      # The stored prefixes are http for carriers that now redirect to https, and a seller pasting
      # from the carrier's own site gets the https form.
      shipment.update!(tracking_url: "https://wwwapps.ups.com/WebTracking/processInputRequest?TypeOfInquiryNumber=T&InquiryNumber1=1Z999AA10123456784")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["UPS", "1Z999AA10123456784"])
    end

    it "matches regardless of the host's case" do
      shipment.update!(tracking_url: "https://WWWAPPS.UPS.COM/WebTracking/processInputRequest?TypeOfInquiryNumber=T&InquiryNumber1=1z999aa10123456784")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["UPS", "1z999aa10123456784"])
    end

    it "returns nothing when the path or query keys differ in case from the carrier's form" do
      # Only the host is case-insensitive. `QTC_TLABELS1` is not a URL USPS serves, so the number
      # after it is not a USPS tracking number and must not become structured evidence.
      # The number is a real USPS one, so only the casing can be what rejects these.
      shipment.update!(tracking_url: "https://tools.usps.com/go/TrackConfirmAction?QTC_TLABELS1=9400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil

      shipment.update!(tracking_url: "https://tools.usps.com/GO/TrackConfirmAction?qtc_tLabels1=9400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing for a URL that is not a known carrier's tracking form" do
      shipment.update!(tracking_url: "https://track.aftership.com/1Z999AA10123456784")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing when the value has no scheme" do
      # The column also holds bare tracking numbers and free-text notes, so text that merely starts
      # with a carrier's host is not a link the seller followed. The number is a real USPS one, so
      # only the missing scheme can be what rejects these.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"].sub(%r{\Ahttps?://}, "")
      shipment.update!(tracking_url: "#{usps}9400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil

      shipment.update!(tracking_url: "see tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=9400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing when the remainder is not a plausible tracking number" do
      # Extra query parameters mean we cannot tell where the number ends, and a wrong number
      # submitted as evidence is worse than none. A remainder that is empty, truncated, or carries a
      # trailing parameter is not a number USPS issued.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      ["#{usps}9400111899223197428490&tRef=fullpage", usps, "#{usps}12", "#{usps}1Z999AA"].each do |url|
        shipment.update!(tracking_url: url)
        expect(shipment.carrier_and_tracking_number_from_url).to be_nil, "expected #{url} to be rejected"
      end
    end

    it "recovers the pair from a value stored with surrounding whitespace" do
      # No writer strips this column, so a trailing newline must not cost the structured evidence.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      shipment.update!(tracking_url: "  #{usps}9400111899223197428490\n")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["USPS", "9400111899223197428490"])
    end

    it "recovers the pair when the pasted whitespace was percent-encoded" do
      # The browser encodes whitespace the seller pasted, so it survives `strip` inside the query
      # string. `%20` leads 1,932 of the newest 200,000 shipments' USPS numbers — without this the
      # single largest population of real tracking numbers derives nothing.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      shipment.update!(tracking_url: "#{usps}%209400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["USPS", "9400111899223197428490"])

      shipment.update!(tracking_url: "#{usps}%0D%0A9400111899223197428490%20")
      expect(shipment.carrier_and_tracking_number_from_url).to eq(["USPS", "9400111899223197428490"])
    end

    it "does not treat a percent-encoded non-whitespace character as trimmable" do
      # `%2F` is a slash, not whitespace. Trimming it would invent a number the seller never gave.
      usps = Shipment::CARRIER_TRACKING_URL_MAPPING["USPS"]
      shipment.update!(tracking_url: "#{usps}%2F9400111899223197428490")
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "returns nothing rather than raising when the value in memory is not valid UTF-8" do
      # Assigned, not saved: the utf8mb4 column drops the invalid byte on write, so anything read
      # back is valid and the guard would never be reached. Unsaved is the only state where the
      # byte survives to `strip`, which raises `Encoding::CompatibilityError` — failing the whole
      # dispute-evidence build instead of skipping one unusable field.
      shipment.tracking_url = "https://tools.usps.com/go/x\xFF".dup.force_encoding("UTF-8")
      expect(shipment.tracking_url.valid_encoding?).to be(false)

      expect { shipment.carrier_and_tracking_number_from_url }.to_not raise_error
      expect(shipment.carrier_and_tracking_number_from_url).to be_nil
    end

    it "keeps a multibyte URL intact rather than mangling it" do
      # `scrub` must only replace invalid bytes; a legitimate non-ASCII path is not one.
      url = "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=9400111899223197428490é"
      shipment.update!(tracking_url: url)

      expect(shipment.reload.tracking_url).to eq(url)
    end

    it "returns nothing when no tracking URL was supplied" do
      expect(create(:shipment, carrier: nil, tracking_number: nil, tracking_url: nil)
               .carrier_and_tracking_number_from_url).to be_nil
    end
  end
end
