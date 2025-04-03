# frozen_string_literal: true

describe SearchIndexModelCommon do
  before do
    @klass = Class.new(User)
    @klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
      include SearchIndexModelCommon
      include Elasticsearch::Model

      index_name "user-fake-index-for-test"

      mappings do
        indexes :first_name, type: :keyword
        indexes :last_name, type: :keyword
        indexes :email, type: :keyword
        indexes :is_active_with_name, type: :boolean
        indexes :active, type: :boolean
        indexes :has_amex, type: :boolean
      end

      ATTRIBUTE_TO_SEARCH_FIELDS = {
        "first_name" => ["first_name", "is_active_with_name"],
        "last_name" => ["last_name", "is_active_with_name"],
        "email" => "email",
        "active" => ["active", "is_active_with_name"],
      }

      def search_field_value(field_name)
        "\#{field_name} value"
      end
    RUBY
  end

  describe ".search_fields" do
    it "returns a list of search fields for the index" do
      expect(@klass.search_fields).to match_array([
                                                    "first_name", "is_active_with_name", "last_name", "email", "active", "has_amex"
                                                  ])
    end
  end

  describe "#as_indexed_json" do
    it "returns json versions" do
      instance = @klass.new
      expect(instance.as_indexed_json).to eq(
        "first_name" => "first_name value",
        "is_active_with_name" => "is_active_with_name value",
        "last_name" => "last_name value",
        "email" => "email value",
        "active" => "active value",
        "has_amex" => "has_amex value",
      )
    end
  end
end
