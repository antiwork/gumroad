# frozen_string_literal: true

require "spec_helper"

describe "InstallmentTracking"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe "click_summary" do
    before do
      @installment = create(:installment, id: 13)
    end

    it "converts encoded urls back into human-readable format" do
      CreatorEmailClickSummary.create!(installment_id: 13,
                                       total_unique_clicks: 2,
                                       urls: { "https://www&#46;gumroad&#46;com" => 1,
                                               "https://www&#46;google&#46;com" => 2 })
      decoded_hash = { "google.com" => 2,
                       "gumroad.com" => 1 }
      urls = @installment.clicked_urls
      expect(urls).to eq decoded_hash
    end
  end

  describe "#click_rate_percent" do
    before do
      @installment = create(:installment, id: 13, customer_count: 4)
    end

    it "computes the click rate correctly" do
      CreatorEmailClickSummary.create!(installment_id: 13,
                                       total_unique_clicks: 2,
                                       urls: { "https://www&#46;gumroad&#46;com" => 2,
                                               "https://www&#46;google&#46;com" => 1 })
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

    it "returns the correct number of clicks" do
      CreatorEmailClickSummary.create!(installment_id: @installment.id,
                                       total_unique_clicks: 2,
                                       urls: { "https://www&#46;gumroad&#46;com" => 2,
                                               "https://www&#46;google&#46;com" => 1 })
      expect(@installment.unique_click_count).to eq 2
    end

    it "does not hit CreatorEmailClickSummary model once the cache is set" do
      CreatorEmailClickSummary.create!(installment_id: @installment.id,
                                       total_unique_clicks: 4,
                                       urls: { "https://www&#46;gumroad&#46;com" => 2,
                                               "https://www&#46;google&#46;com" => 1 })
      # Read once and set the cache
      @installment.unique_click_count

      expect(CreatorEmailClickSummary).not_to receive(:where).with(installment_id: @installment.id)
      unique_click_count = @installment.unique_click_count

      expect(unique_click_count).to eq 4
    end
  end

  describe "#unique_open_count" do
    before do
      @installment = create(:installment, customer_count: 4)
    end

    it "does not hit CreatorEmailOpenEvent model once the cache is set" do
      3.times { CreatorEmailOpenEvent.create!(installment_id: @installment.id) }

      # Read once and set the cache
      @installment.unique_open_count

      expect(CreatorEmailOpenEvent).not_to receive(:where).with(installment_id: @installment.id)
      unique_open_count = @installment.unique_open_count

      expect(unique_open_count).to eq 3
    end
  end
end
