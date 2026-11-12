# frozen_string_literal: true

# Not paper-trailed: a live credential must not land in `versions`.
class MetaConversionsSetting < ApplicationRecord
  belongs_to :user

  validates :access_token, presence: true
end
