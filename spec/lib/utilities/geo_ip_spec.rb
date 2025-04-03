# frozen_string_literal: true

require "spec_helper"

describe GeoIp do
  describe ".lookup" do
    let(:result) { described_class.lookup(ip) }

    describe "an IP to location match is not possible" do
      let(:ip) { "127.0.0.1" }

      it "returns a nil result" do
        expect(result).to eq(nil)
      end
    end

    describe "an IP to location match is possible" do
      let(:ip) { "104.193.168.19" }

      it "returns a result" do
        expect(result.country_name).to eq("United States")
        expect(result.country_code).to eq("US")
        expect(result.region_name).to eq("CA")
        expect(result.city_name).to eq("San Francisco")
        expect(result.postal_code).to eq("94110")
        expect(result.latitude).to eq(nil)
        expect(result.longitude).to eq(nil)
      end
    end

    describe "an IPv6 to location match is possible" do
      let(:ip) { "2001:861:5bc0:cb60:500d:3535:e6a7:62a0" }

      it "returns a result" do
        expect(result.country_name).to eq("France")
        expect(result.country_code).to eq("FR")
        expect(result.city_name).to eq("Belfort")
        expect(result.postal_code).to eq("90000")
        expect(result.latitude).to eq(nil)
        expect(result.longitude).to eq(nil)
      end
    end

    describe "an IP to location match is possible but the underlying GEOIP has invalid UTF-8 in fields" do
      let(:ip) { "104.193.168.19" }

      before do
        expect(GEOIP).to receive(:city).and_return(
          double(
            country: double({ name: "Unit\xB7ed States", iso_code: "U\xB7S" }),
            most_specific_subdivision: double({ iso_code: "C\xB7A" }),
            city: double({ name: "San F\xB7rancisco" }),
            postal: double({ code: "941\xB703" }),
            location: double({ latitude: "103\xB7103", longitude: "103\xB7103" })
          )
        )
      end

      it "returns a result" do
        expect(result.country_name).to eq("Unit?ed States")
        expect(result.country_code).to eq("U?S")
        expect(result.region_name).to eq("C?A")
        expect(result.city_name).to eq("San F?rancisco")
        expect(result.postal_code).to eq("941?03")
        expect(result.latitude).to eq("103?103")
        expect(result.longitude).to eq("103?103")
      end
    end
  end
end
