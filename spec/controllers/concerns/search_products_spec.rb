# frozen_string_literal: true

require "spec_helper"

describe SearchProducts do
  # Create a test controller that includes the concern
  controller(ApplicationController) do
    include SearchProducts

    def index
      format_search_params!
      render json: params
    end
  end

  describe "#format_search_params!" do
    context "with offer_codes parameter" do
      context "when feature flag is active" do
        before do
          Feature.activate(:offer_codes_search)
          routes.draw { get "index" => "anonymous#index" }
        end

        after do
          Feature.deactivate(:offer_codes_search)
        end

        it "filters allowed offer codes from string" do
          get :index, params: { offer_codes: "BLACKFRIDAY2025,SUMMER2025" }
          expect(JSON.parse(response.body)["offer_codes"]).to eq(["BLACKFRIDAY2025"])
        end

        it "filters allowed offer codes from array" do
          get :index, params: { offer_codes: ["BLACKFRIDAY2025", "SUMMER2025"] }
          expect(JSON.parse(response.body)["offer_codes"]).to eq(["BLACKFRIDAY2025"])
        end

        it "returns empty array when no allowed codes are present" do
          get :index, params: { offer_codes: "SUMMER2025,WINTER2025" }
          expect(JSON.parse(response.body)["offer_codes"]).to eq([])
        end

        it "preserves allowed codes" do
          get :index, params: { offer_codes: "BLACKFRIDAY2025" }
          expect(JSON.parse(response.body)["offer_codes"]).to eq(["BLACKFRIDAY2025"])
        end
      end

      context "when feature flag is inactive" do
        before do
          Feature.deactivate(:offer_codes_search)
          routes.draw { get "index" => "anonymous#index" }
        end

        it "removes offer_codes from params" do
          get :index, params: { offer_codes: "BLACKFRIDAY2025" }
          expect(JSON.parse(response.body)["offer_codes"]).to be_nil
        end
      end
    end

    context "with other parameters" do
      before do
        routes.draw { get "index" => "anonymous#index" }
      end

      it "parses tags from string" do
        get :index, params: { tags: "design,art" }
        expect(JSON.parse(response.body)["tags"]).to eq(["design", "art"])
      end

      it "parses filetypes from string" do
        get :index, params: { filetypes: "pdf,video" }
        expect(JSON.parse(response.body)["filetypes"]).to eq(["pdf", "video"])
      end

      it "converts size to integer" do
        get :index, params: { size: "20" }
        expect(JSON.parse(response.body)["size"]).to eq(20)
      end
    end
  end
end

