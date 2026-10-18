# frozen_string_literal: true

require "spec_helper"

describe MailerHelper do
  describe "#from_email_address_with_header" do
    it "returns a plain Name <addr> header for a name without specials" do
      expect(from_email_address_with_header("Bob", "creators@example.com"))
        .to eq("Bob <creators@example.com>")
    end

    it "quotes a name containing a comma so the address still parses" do
      expect(from_email_address_with_header("Smith, John", "creators@example.com"))
        .to eq("\"Smith, John\" <creators@example.com>")
    end

    it "quotes a name containing angle brackets" do
      expect(from_email_address_with_header("a<b>x</b>", "creators@example.com"))
        .to eq("\"a<b>x</b>\" <creators@example.com>")
    end

    it "still sanitizes the name before quoting" do
      expect(from_email_address_with_header("John: The Creator", "creators@example.com"))
        .to eq("John The Creator <creators@example.com>")
    end
  end

  describe "#from_email_address_name" do
    context "when name doesn't contain special characters" do
      it "returns the name" do
        expect(from_email_address_name("John The Creator")).to eq("John The Creator")
      end
    end

    context "when name contains colon character" do
      it "strips the colon and returns the cleaned name" do
        expect(from_email_address_name("John: The Creator")).to eq("John The Creator")
      end
    end
  end
end
