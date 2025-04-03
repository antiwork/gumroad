# frozen_string_literal: true

require "spec_helper"

describe TagsController do
  describe "List tags" do
    it "Shows matching tags alphabetically" do
      %w[Armadillo Antelope Marmoset Aardvark].each { |animal| create(:tag, name: animal) }
      get(:index, params: { text: "a" })
      expect(response.parsed_body.length).to eq(3)
      expect(response.parsed_body.first["name"]).to eq("aardvark")
      expect(response.parsed_body.first["uses"]).to eq(0)
      expect(response.parsed_body.last["name"]).to eq("armadillo")
      expect(response.parsed_body.last["uses"]).to eq(0)
    end

    it "Shows popular tags first" do
      5.times { create(:product).tag!("Porcupine") }
      2.times { create(:product).tag!("Pangolin") }
      get(:index, params: { text: "p" })
      expect(response.parsed_body.first["name"]).to eq("porcupine")
      expect(response.parsed_body.first["uses"]).to eq(5)
      expect(response.parsed_body.last["name"]).to eq("pangolin")
      expect(response.parsed_body.last["uses"]).to eq(2)
    end

    it "Shows success false if no text is passed in" do
      get(:index)
      expect(response.parsed_body["success"]).to eq(false)
    end
  end
end
