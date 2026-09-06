# frozen_string_literal: true

require "spec_helper"

describe JsonData do
  # This can be any model, but I'm using the Purchase model for the tests. I could not
  # find a way to create a mock model which included JsonData.
  let(:model) do
    create(:purchase)
  end

  describe "attr_json_data_accessor" do
    describe "attr_json_data_reader" do
      it "returns the value of the attribute" do
        model.json_data = { "locale" => :en }
        expect(model.locale.to_sym).to eq(:en)
      end

      it "returns the default value when attribute not set or blank" do
        model.json_data = { "locale" => nil }
        expect(model.locale.to_sym).to eq(:en)
      end
    end

    describe "attr_json_data_writer" do
      it "sets the attribute in json_data" do
        model.locale = :ja
        expect(model.json_data["locale"].to_sym).to eq(:ja)
      end
    end
  end

  describe "json_data" do
    before do
      model.json_data = nil
    end

    it "returns an empty hash if not initialized" do
      expect(model.json_data).to eq({})
    end
  end

  describe "json_data_for_attr" do
    it "gets the attribute in json_data" do
      model.json_data = { "attribute" => "hi" }
      expect(model.json_data_for_attr("attribute", default: "default")).to eq("hi")
    end

    it "returns the default if json_data is nil" do
      model.json_data = nil
      expect(model.json_data_for_attr("attribute", default: "default")).to eq("default")
    end

    it "returns the default if the attribute does not exist in json_data" do
      model.json_data = {}
      expect(model.json_data_for_attr("attribute", default: "default")).to eq("default")
    end

    it "returns the default if the attribute does exist but is not present" do
      model.json_data = { "attribute" => "" }
      expect(model.json_data_for_attr("attribute", default: "default")).to eq("default")
    end

    it "returns the default if the attribute does exist but is nil" do
      model.json_data = { "attribute" => nil }
      expect(model.json_data_for_attr("attribute", default: "default")).to eq("default")
    end

    it "returns nil if the attribute does not exist in json_data and no default" do
      model.json_data = {}
      expect(model.json_data_for_attr("attribute")).to be_nil
    end
  end

  describe "set_json_data_for_attr" do
    it "sets the attribute in json_data" do
      model.set_json_data_for_attr("attribute", "hi")
      expect(model.json_data["attribute"]).to eq("hi")
    end
  end

  describe "concurrent writers" do
    let!(:user) { create(:user) }

    it "keeps an attribute another writer set after this instance loaded json_data" do
      stale = User.find(user.id)
      stale.payout_threshold_cents

      fresh = User.find(user.id)
      fresh.au_backtax_sales_cents = 4321
      fresh.save!

      stale.payout_threshold_cents = 9999
      stale.save!

      expect(user.reload.au_backtax_sales_cents).to eq(4321)
      expect(user.payout_threshold_cents).to eq(9999)
    end

    it "still deletes a key this instance removed" do
      user.update!(gumroad_day_timezone: "UTC")

      stale = User.find(user.id)
      stale.json_data

      User.find(user.id).update!(au_backtax_sales_cents: 4321)

      stale.json_data.delete("gumroad_day_timezone")
      stale.save!

      expect(user.reload.json_data).not_to have_key("gumroad_day_timezone")
      expect(user.au_backtax_sales_cents).to eq(4321)
    end

    it "lets this instance overwrite a key the other writer also set" do
      stale = User.find(user.id)
      stale.json_data

      User.find(user.id).update!(au_backtax_sales_cents: 4321)

      stale.au_backtax_sales_cents = 1111
      stale.save!

      expect(user.reload.au_backtax_sales_cents).to eq(1111)
    end

    it "does not read the row back when json_data is untouched" do
      expect(User).not_to receive(:unscoped)

      user.update!(name: "Fresh name")
    end
  end

  describe "corrupt non-Hash json_data" do
    let!(:user) { create(:user) }

    it "allows a rewrite save when the stored value is a JSON string scalar" do
      user.update_column(:json_data, '"not a hash"')
      user.reload
      user[:json_data] = {}
      user.payout_threshold_cents = 1234

      expect { user.save! }.not_to raise_error
      expect(user.reload.payout_threshold_cents).to eq(1234)
    end
  end
end
