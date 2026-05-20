# frozen_string_literal: true

class PageVersion < ApplicationRecord
  belongs_to :page
  belongs_to :parent, class_name: "PageVersion", optional: true
  has_many :children, class_name: "PageVersion", foreign_key: :parent_id, dependent: :nullify

  validates :html, presence: true
  validates :prompt, presence: true
end
