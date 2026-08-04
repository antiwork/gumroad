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

    context "with taxonomy attribute filter parameters" do
      before do
        routes.draw { get "index" => "anonymous#index" }
        taxonomy = create(:taxonomy)
        TaxonomyAttribute.create!(taxonomy:, name: "format", label: "Format", value_type: "enum", values: ["OTF"])
        TaxonomyAttribute.create!(taxonomy:, name: "license", label: "License", value_type: "enum", values: ["Commercial"])
      end

      it "coerces nested taxonomy attribute filter params into scalar tokens" do
        get :index, params: { taxonomy_attribute_filters: { "0" => "format:otf", "1" => ["license:commercial"] } }

        expect(JSON.parse(response.body)["taxonomy_attribute_filters"]).to eq(["format:otf", "license:commercial"])
      end

      it "caps the number of tokens so a crafted URL cannot emit an unbounded number of ES clauses" do
        valid_tokens = ["format:otf", "license:commercial"]
        tokens = valid_tokens + (1..50).map { |i| "attr#{i}:value" }
        get :index, params: { taxonomy_attribute_filters: tokens.join(",") }

        parsed = JSON.parse(response.body)["taxonomy_attribute_filters"]
        expect(parsed).to match_array(valid_tokens)
      end

      it "still caps once invalid tokens are removed, when the surviving set exceeds the limit" do
        taxonomy = TaxonomyAttribute.first.taxonomy
        many_values = (1..25).map { |i| "v#{i}" }
        TaxonomyAttribute.create!(taxonomy:, name: "size", label: "Size", value_type: "enum", values: many_values)
        tokens = many_values.map { |v| "size:#{v}" }
        get :index, params: { taxonomy_attribute_filters: tokens.join(",") }

        parsed = JSON.parse(response.body)["taxonomy_attribute_filters"]
        expect(parsed.size).to eq(Product::Searchable::MAX_TAXONOMY_ATTRIBUTE_FILTER_TOKENS)
      end

      it "drops duplicate tokens before applying the cap" do
        get :index, params: { taxonomy_attribute_filters: "format:otf,format:otf,license:commercial" }

        expect(JSON.parse(response.body)["taxonomy_attribute_filters"]).to eq(["format:otf", "license:commercial"])
      end

      it "applies the allowlist before the cap so junk tokens cannot crowd out a valid one" do
        tokens = (1..Product::Searchable::MAX_TAXONOMY_ATTRIBUTE_FILTER_TOKENS).map { |i| "attr#{i}:value" } + ["format:otf"]
        get :index, params: { taxonomy_attribute_filters: tokens.join(",") }

        expect(JSON.parse(response.body)["taxonomy_attribute_filters"]).to eq(["format:otf"])
      end

      it "drops tokens for attributes/values that are no longer active" do
        get :index, params: { taxonomy_attribute_filters: "format:otf,format:tiff" }

        expect(JSON.parse(response.body)["taxonomy_attribute_filters"]).to eq(["format:otf"])
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

      it "parses tags from nested hash params" do
        get :index, params: { tags: { "0" => "audio", "1" => "3d-models" } }
        expect(JSON.parse(response.body)["tags"]).to eq(["audio", "3d models"])
      end

      it "parses filetypes from string" do
        get :index, params: { filetypes: "pdf,video" }
        expect(JSON.parse(response.body)["filetypes"]).to eq(["pdf", "video"])
      end

      it "parses ids from string" do
        get :index, params: { ids: "abc,def, ghi" }
        expect(JSON.parse(response.body)["ids"]).to eq(["abc", "def", "ghi"])
      end

      it "converts size to integer" do
        get :index, params: { size: "20" }
        expect(JSON.parse(response.body)["size"]).to eq(20)
      end

      it "converts size from array to integer" do
        get :index, params: { size: ["20", "30"] }
        expect(JSON.parse(response.body)["size"]).to eq(20)
      end

      it "converts from to integer when present" do
        get :index, params: { from: "5" }
        expect(JSON.parse(response.body)["from"]).to eq(5)
      end

      it "converts from from array to integer" do
        get :index, params: { from: ["10", "20"] }
        expect(JSON.parse(response.body)["from"]).to eq(10)
      end
    end
  end
end
