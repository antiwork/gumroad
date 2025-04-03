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
end
