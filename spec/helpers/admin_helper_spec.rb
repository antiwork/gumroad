# frozen_string_literal: true

require "spec_helper"

describe AdminHelper do
  include ApplicationHelper

  describe "markdown" do
    it "changes a string of plain text to the exact same, with paragraph tags and linebreak" do
      input = "To be, or not to be, that is the question"
      output = markdown(input)
      expect("<p>#{input}</p>\n").to eq(output)
    end

    it "handles headers appropriately" do
      input = "#Act I\n##Scene i"
      output = markdown(input)
      expect(output).to include("<h1>Act I</h1>")
      expect(output).to include("<h2>Scene i</h2>")
    end

    it "strips user included html (prevent xss)" do
      input = "<script>alert(Your ass has been p0wned)</script>"
      output = markdown(input)
      expect(output).to eq("<p>alert(Your ass has been p0wned)</p>\n")
    end
  end

  describe "#product_type_label" do
    subject(:product_type) { product_type_label(product) }

    context "when it is a digital product" do
      let(:product) { create(:product_with_pdf_file) }

      it { is_expected.to eq("Product") }
    end

    context "when it is a legacy subscription product" do
      let(:product) { create(:subscription_product) }

      it { is_expected.to eq("Subscription") }
    end

    context "when it is a membership product" do
      let(:product) { create(:membership_product) }

      it { is_expected.to eq("Membership") }
    end
  end

  describe "#link_to_processor" do
    let(:charge_processor_id) { "dummy_charge_processor_id" }
    let(:charge_id) { "dummy_charge_id" }
    let(:charged_using_gumroad_account) { true }
    let(:transaction_url) { "https://example.com" }

    it "returns nil if charge_id is nil" do
      result = link_to_processor(charge_processor_id, nil, target: "_blank")
      expect(result).to be(nil)
    end

    it "returns a link if transaction url present" do
      allow(ChargeProcessor).to receive(:transaction_url_for_admin).with(charge_processor_id, charge_id, charged_using_gumroad_account).and_return(transaction_url)

      result = link_to_processor(charge_processor_id, charge_id, charged_using_gumroad_account, target: "_blank")
      expect(result).to eq link_to(charge_id, transaction_url, target: "_blank")
    end

    it "returns charge id without link if transaction url is not present" do
      allow(ChargeProcessor).to receive(:transaction_url_for_admin).with(charge_processor_id, charge_id, charged_using_gumroad_account).and_return(nil)
      result = link_to_processor(charge_processor_id, charge_id, charged_using_gumroad_account, target: "_blank")
      expect(result).to eq(charge_id)
    end
  end

  describe "#format_datetime_with_relative_tooltip" do
    it "returns placeholder when value is nil" do
      result = format_datetime_with_relative_tooltip(nil, placeholder: "Nope")
      expect(result).to eq("Nope")
    end

    it "returns exact date with relative time in tooltip for future dates" do
      datetime = DateTime.parse("2022-02-22 10:00:01")
      travel_to(datetime) do
        puts Time.current
        result = format_datetime_with_relative_tooltip(1.day.from_now)
        expect(result).to eq('<span title="1 day from now">Feb 23, 2022 at 10:00 AM</span>')
      end
    end

    it "returns exact date with relative time in tooltip for past dates" do
      datetime = DateTime.parse("2022-02-22 10:00:01")
      travel_to(datetime) do
        puts Time.current
        result = format_datetime_with_relative_tooltip(1.day.ago)
        expect(result).to eq('<span title="1 day ago">Feb 21, 2022 at 10:00 AM</span>')
      end
    end
  end

  describe "#with_tooltip" do
    it "returns element with tooltip" do
      result = with_tooltip(tip: "Tooltip info goes here", position: "s") { "I have a tooltip!" }
      expect(result).to include("I have a tooltip!")
      expect(result).to include("Tooltip info goes here".html_safe)
    end
  end

  describe "#blocked_email_tooltip" do
    let(:user) { User.last }
    let(:email) { "john@example.com" }
    let!(:email_blocked_object) { BlockedObject.block!(:email, email, user) }
    let!(:email_domain_blocked_object) { BlockedObject.block!(:email_domain, Mail::Address.new(email).domain, user) }

    it "includes email and email domain tooltip information" do
      result = blocked_email_tooltip(email)
      expect(result).to include("Email blocked")
      expect(result).to include("example.com blocked")
    end

    context "with unblocked email domain" do
      before do
        email_blocked_object.unblock!
      end

      it "includes email information" do
        result = blocked_email_tooltip(email)
        expect(result).to_not include("Email blocked")
        expect(result).to include("example.com blocked")
      end
    end

    context "with unblocked email domain" do
      before do
        email_domain_blocked_object.unblock!
      end

      it "includes email information" do
        result = blocked_email_tooltip(email)
        expect(result).to include("Email blocked")
        expect(result).to_not include("example.com blocked")
      end
    end

    context "with both email and email domain unblocked" do
      before do
        email_blocked_object.unblock!
        email_domain_blocked_object.unblock!
      end

      it "returns nil" do
        result = blocked_email_tooltip(email)
        expect(result).to be(nil)
      end
    end
  end

  describe "#current_user_props" do
    let(:admin) { create(:admin_user, username: "gumroadian") }
    let(:seller) { create(:named_seller) }

    it "returns the current user props" do
      expect(current_user_props(admin, seller)).to eq(
        {
          name: "gumroadian",
          avatar_url: admin.avatar_url,
          impersonated_user: {
            name: "Seller",
            avatar_url: seller.avatar_url,
          },
        }
      )
    end
  end
end
