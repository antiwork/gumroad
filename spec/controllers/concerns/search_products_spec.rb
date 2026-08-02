# frozen_string_literal: true

require "spec_helper"

describe SearchProducts, type: :controller do
  controller(ApplicationController) do
    include SearchProducts

    def normalize(params)
      normalize_search_param_values!(params)
    end
  end

  describe "#normalize_search_param_values!" do
    it "coerces nested taxonomy attribute filter params into scalar tokens" do
      params = ActionController::Parameters.new(taxonomy_attribute_filters: { "0" => "format:otf", "1" => ["license:commercial"] })

      controller.normalize(params)

      expect(params[:taxonomy_attribute_filters]).to eq(["format:otf", "license:commercial"])
    end
  end
end
