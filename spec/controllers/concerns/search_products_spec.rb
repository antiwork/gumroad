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
    context "with offer_code parameter" do
      context "when feature flag is active" do
        before do
          Feature.activate(:offer_codes_search)
          routes.draw { get "index" => "anonymous#index" }
        end

        after do
          Feature.deactivate(:offer_codes_search)
        end

        it "preserves allowed offer code" do
          get :index, params: { offer_code: "BLACKFRIDAY2025" }
          expect(JSON.parse(response.body)["offer_code"]).to eq("BLACKFRIDAY2025")
        end

        it "returns __no_match__ when code is not allowed" do
          get :index, params: { offer_code: "SUMMER2025" }
          expect(JSON.parse(response.body)["offer_code"]).to eq("__no_match__")
        end
      end

      context "when feature flag is inactive" do
        before do
          Feature.deactivate(:offer_codes_search)
          routes.draw { get "index" => "anonymous#index" }
        end

        it "blocks offer_code when feature is disabled and no secret key" do
          get :index, params: { offer_code: "BLACKFRIDAY2025" }
          expect(JSON.parse(response.body)["offer_code"]).to eq("__no_match__")
        end

        context "with secret key" do
          before do
            ENV["SECRET_FEATURE_KEY"] = "test_secret_key_123"
          end

          after do
            ENV.delete("SECRET_FEATURE_KEY")
          end

          it "allows offer_code when valid secret key is provided" do
            get :index, params: { offer_code: "BLACKFRIDAY2025", feature_key: "test_secret_key_123" }
            expect(JSON.parse(response.body)["offer_code"]).to eq("BLACKFRIDAY2025")
          end

          it "blocks offer_code when invalid secret key is provided" do
            get :index, params: { offer_code: "BLACKFRIDAY2025", feature_key: "wrong_key" }
            expect(JSON.parse(response.body)["offer_code"]).to eq("__no_match__")
          end

          it "blocks offer_code when secret key is empty" do
            get :index, params: { offer_code: "BLACKFRIDAY2025", feature_key: "" }
            expect(JSON.parse(response.body)["offer_code"]).to eq("__no_match__")
          end

          it "blocks non-allowed offer_code even with valid secret key" do
            get :index, params: { offer_code: "SUMMER2025", feature_key: "test_secret_key_123" }
            expect(JSON.parse(response.body)["offer_code"]).to eq("__no_match__")
          end
        end
      end
    end

    context "without offer_code parameter" do
      before do
        routes.draw { get "index" => "anonymous#index" }
      end

      it "does not modify params when offer_code is not present" do
        get :index, params: { tags: "design" }
        expect(JSON.parse(response.body)["offer_code"]).to be_nil
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
