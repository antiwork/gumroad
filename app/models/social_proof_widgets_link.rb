# frozen_string_literal: true

class SocialProofWidgetsLink < ApplicationRecord
  belongs_to :social_proof_widget
  belongs_to :link

  validates :social_proof_widget_id, uniqueness: { scope: :link_id, message: "This widget is already linked to the given link." }
end
