module Ai
  class TagSuggestionsService
    def initialize(current_seller:)
      @current_seller = current_seller
    end

    def generate_tags(product_name:, description: nil)
      # Mock response for demo - replace with OpenAI in production
      mock_tags = [
        "design system",
        "ui kit",
        "figma",
        "components",
        "templates",
        "design resources",
        "web design"
      ]

      mock_tags.shuffle.take(rand(5..7))
    end
  end
end
