# frozen_string_literal: true

require "spec_helper"

describe PurchaseUrlParameter do
  describe "Purchase#url_parameters accessors" do
    let(:purchase) { build(:purchase) }

    it "returns nil when nothing has been assigned" do
      expect(purchase.url_parameters).to be_nil
    end

    it "stores an assigned hash in the associated record" do
      purchase.url_parameters = { "discord_id" => "123" }

      expect(purchase.url_parameters).to eq("discord_id" => "123")
      expect(purchase.purchase_url_parameter.params).to eq("discord_id" => "123")
    end

    it "returns nil after a previously assigned value is overwritten with nil" do
      # Purchase::CreateService mass-assigns the raw url_parameters string when
      # building the purchase, then assigns the parsed value afterwards — which
      # is nil when the string isn't valid JSON. Clearing must fully discard the
      # earlier assignment.
      purchase.url_parameters = "{{"
      purchase.url_parameters = nil

      expect(purchase.url_parameters).to be_nil
      expect(purchase.purchase_url_parameter).to be_nil
    end

    it "persists the value across a database reload" do
      purchase = create(:purchase)
      purchase.url_parameters = { "discord_id" => "123", "plan" => "pro" }
      purchase.save!

      expect(Purchase.find(purchase.id).url_parameters).to eq("discord_id" => "123", "plan" => "pro")
    end

    it "destroys the persisted record when cleared and saved" do
      purchase = create(:purchase)
      purchase.url_parameters = { "discord_id" => "123" }
      purchase.save!

      reloaded = Purchase.find(purchase.id)
      reloaded.url_parameters = nil

      expect(reloaded.url_parameters).to be_nil

      reloaded.save!

      expect(Purchase.find(purchase.id).url_parameters).to be_nil
      expect(PurchaseUrlParameter.where(purchase_id: purchase.id)).to be_empty
    end
  end
end
