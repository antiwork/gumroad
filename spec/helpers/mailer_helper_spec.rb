# frozen_string_literal: true

require "spec_helper"

describe MailerHelper do
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
