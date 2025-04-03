# frozen_string_literal: true

class Integration < ApplicationRecord
  include FlagShihTzu
  include JsonData
  include TimestampScopes

  CIRCLE = "circle"
  DISCORD = "discord"
  ZOOM = "zoom"
  GOOGLE_CALENDAR = "google_calendar"

  ALL_NAMES = [CIRCLE, DISCORD, ZOOM, GOOGLE_CALENDAR]

  has_one :product_integration, dependent: :destroy
  scope :by_name, -> (name) { where(type: Integration.type_for(name)) }

  has_flags 1 => :keep_inactive_members,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  def as_json(*)
    {
      name:,
      keep_inactive_members:,
      integration_details: json_data
    }
  end

  def self.type_for(name)
    "#{name.capitalize.camelize}Integration"
  end

  def self.class_for(name)
    case name
    when CIRCLE
      CircleIntegration
    when DISCORD
      DiscordIntegration
    when ZOOM
      ZoomIntegration
    when GOOGLE_CALENDAR
      GoogleCalendarIntegration
    end
  end

  def self.enabled_integrations_for(purchase)
    ALL_NAMES.index_with { |name| class_for(name).is_enabled_for(purchase) }
  end

  def name
    type.chomp("Integration").underscore
  end

  def disconnect!
    true
  end

  def same_connection?(integration)
    false
  end

  def self.connection_settings
    []
  end
end
