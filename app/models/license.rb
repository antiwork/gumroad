# frozen_string_literal: true

class License < ApplicationRecord
  has_paper_trail only: %i[disabled_at serial]

  include FlagShihTzu
  include ExternalId

  validates_numericality_of :uses, greater_than_or_equal_to: 0
  validates_presence_of :serial

  belongs_to :link, optional: true
  belongs_to :purchase, optional: true
  belongs_to :imported_customer, optional: true

  before_validation :generate_serial, on: :create

  has_flags 1 => :DEPRECATED_is_pregenerated,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  def generate_serial
    return if serial.present?

    self.serial = SecureRandom.uuid.upcase.delete("-").scan(/.{8}/).join("-")
  end

  def disabled?
    disabled_at?
  end

  def disable!
    self.disabled_at = Time.current
    save!
  end

  def enable!
    self.disabled_at = nil
    save!
  end

  def rotate!
    self.serial = nil
    generate_serial
    save!
  end
end
