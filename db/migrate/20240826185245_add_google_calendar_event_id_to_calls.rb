# frozen_string_literal: true

class AddGoogleCalendarEventIdToCalls < ActiveRecord::Migration[4.2]
  def change
    add_column :calls, :google_calendar_event_id, :string
  end
end
