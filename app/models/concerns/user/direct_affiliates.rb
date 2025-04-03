# frozen_string_literal: true

module User::DirectAffiliates
  extend ActiveSupport::Concern

  included do
    has_many :direct_affiliates, foreign_key: :seller_id, class_name: "DirectAffiliate"
  end
end
