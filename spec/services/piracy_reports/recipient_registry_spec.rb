# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::RecipientRegistry do
  describe ".for_host" do
    let(:google) { described_class::Entry.new(name: "Google LLC", email: "dmca@example.com", source_url: "https://dmca.copyright.gov/osp/google") }
    let(:drive) { described_class::Entry.new(name: "Google Drive", email: "drive-dmca@example.com", source_url: "https://dmca.copyright.gov/osp/drive") }

    before { allow(described_class).to receive(:entries).and_return("google.com" => google, "drive.google.com" => drive, "10.9.1.1" => google, "9.1.1" => drive) }

    it "prefers the exact host, then walks up to its parent domains" do
      expect(described_class.for_host("drive.google.com")).to eq(drive)
      expect(described_class.for_host("sites.google.com")).to eq(google)
      expect(described_class.for_host("WWW.Google.com.")).to eq(google)
    end

    it "does not match a top-level domain alone or a different domain" do
      expect(described_class.for_host("google.org")).to be_nil
      expect(described_class.for_host("notgoogle.com")).to be_nil
    end

    it "matches an IP address only exactly, never by its trailing octets" do
      expect(described_class.for_host("10.9.1.1")).to eq(google)
      expect(described_class.for_host("20.9.1.1")).to be_nil
    end
  end

  describe "config/piracy_recipients.yml" do
    it "holds only complete entries that point outside Gumroad" do
      described_class.entries.each do |host, entry|
        expect(host).to eq(PiracyReport.normalized_host(host))
        expect(PiracyReport.gumroad_host?(host)).to be(false), "#{host} is a Gumroad host"
        expect(entry.name).to be_present, "#{host} has no name"
        expect(EmailFormatValidator.valid?(entry.email)).to be(true), "#{host} has an invalid email"
        expect(PiracyReport.gumroad_host?(entry.email.split("@").last)).to be(false), "#{host} points at a Gumroad address"
        expect(PiracyReport.parse_http_url(entry.source_url)).to be_present, "#{host} has no source_url"
      end
    end
  end
end
