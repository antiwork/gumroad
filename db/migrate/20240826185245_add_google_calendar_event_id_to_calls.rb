# frozen_string_literal: true

class AddGoogleCalendarEventIdToCalls < ActiveRecord::Migration[7.1]
  def change
    add_column :calls, :google_calendar_event_id, :string
  end
end
