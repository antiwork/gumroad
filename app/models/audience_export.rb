# frozen_string_literal: true

class AudienceExport < ApplicationRecord
  belongs_to :seller, class_name: "User"
  belongs_to :recipient, class_name: "User"
  has_many :chunks, class_name: "AudienceExportChunk", foreign_key: :export_id, dependent: :delete_all

  serialize :audience_options, type: Hash, coder: YAML

  validates :external_id, presence: true, uniqueness: true
  validates :audience_options, presence: true

  before_validation :set_external_id, on: :create

  def save(**options, &block)
    retries = 0
    begin
      super
    rescue ActiveRecord::RecordNotUnique => e
      if e.message.include?("external_id") && retries < 10
        retries += 1
        self.external_id = self.class.generate_external_id
        retry
      else
        raise
      end
    end
  end

  private
    def set_external_id
      self.external_id ||= self.class.generate_external_id
    end

    def self.generate_external_id
      SecureRandom.alphanumeric(12).downcase
    end
end
