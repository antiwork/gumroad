# frozen_string_literal: true

require "spec_helper"

describe "InstallmentTracking"  do
  def mailer_method
    "CreatorContactingCustomersMailer.purchase_installment"
  end

  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  def record_click(installment, recipient:, url:)
    EmailEngagementDynamoStore.record_click(
      installment_id: installment.id, mailer_method:, mailer_args: recipient, click_url: url
    )
  end

  describe "click_summary" do
    before do
      @installment = create(:installment)
    end

    it "converts encoded urls back into human-readable format" do
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;google&#46;com")
      record_click(@installment, recipient: "[2, 2]", url: "https://www&#46;google&#46;com")
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;gumroad&#46;com")

      decoded_hash = { "google.com" => 2,
                       "gumroad.com" => 1 }
      urls = @installment.clicked_urls
      expect(urls).to eq decoded_hash
    end
  end

  describe "#click_rate_percent" do
    before do
      @installment = create(:installment, customer_count: 4)
    end

    it "computes the click rate correctly" do
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;gumroad&#46;com")
      record_click(@installment, recipient: "[2, 2]", url: "https://www&#46;google&#46;com")

      expect(@installment.click_rate_percent).to eq 50.0
    end
  end

  describe "#unique_click_count" do
    before do
      @installment = create(:installment, customer_count: 4)
    end

    it "returns 0 if there have been no clicks" do
      expect(@installment.unique_click_count).to eq 0
    end

    it "returns the number of unique recipient and url clicks" do
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;gumroad&#46;com")
      record_click(@installment, recipient: "[2, 2]", url: "https://www&#46;google&#46;com")
      # A repeat of an already-counted pair changes nothing.
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;gumroad&#46;com")

      expect(@installment.unique_click_count).to eq 2
    end

    it "does not keep a stale cached zero after later DynamoDB writes" do
      Rails.cache.write(@installment.key_for_cache(:unique_click_count), 0)

      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;gumroad&#46;com")
      record_click(@installment, recipient: "[1, 1]", url: "https://www&#46;google&#46;com")
      record_click(@installment, recipient: "[2, 2]", url: "https://www&#46;gumroad&#46;com")
      record_click(@installment, recipient: "[3, 3]", url: "https://www&#46;google&#46;com")

      expect(Installment.find(@installment.id).unique_click_count).to eq 4
    end
  end

  describe "#unique_open_count" do
    before do
      @installment = create(:installment, customer_count: 4)
    end

    it "does not keep a stale cached zero after later DynamoDB writes" do
      Rails.cache.write(@installment.key_for_cache(:unique_open_count), 0)

      3.times do |i|
        EmailEngagementDynamoStore.record_open(
          installment_id: @installment.id, mailer_method:, mailer_args: "[#{i}, #{i}]"
        )
      end

      expect(Installment.find(@installment.id).unique_open_count).to eq 3
    end
  end
end
