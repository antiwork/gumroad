# frozen_string_literal: true

# A module to include the WithProductFiles module
# and allow for has_and_belongs_to_many relationships
# for product files
module WithProductFilesManyToMany
  extend ActiveSupport::Concern

  included do
    include WithProductFiles
    has_and_belongs_to_many :product_files
  end
end
