# frozen_string_literal: true

class RemoveIntegrationTypeFromIntegration < ActiveRecord::Migration[7.0]
  def up
    remove_column :integrations, :integration_type
  end

  def down
    add_column :integrations, :integration_type, :string

    [CircleIntegration, DiscordIntegration, GoogleCalendarIntegration, ZoomIntegration].each do |klass|
      klass.reset_column_information
    end
    CircleIntegration.in_batches do |relation|
      ReplicaLagWatcher.watch
      relation.update_all(integration_type: "circle")
    end
    DiscordIntegration.in_batches do |relation|
      ReplicaLagWatcher.watch
      relation.update_all(integration_type: "discord")
    end
    GoogleCalendarIntegration.in_batches do |relation|
      ReplicaLagWatcher.watch
      relation.update_all(integration_type: "google_calendar")
    end
    ZoomIntegration.in_batches do |relation|
      ReplicaLagWatcher.watch
      relation.update_all(integration_type: "zoom")
    end

    change_column_null :integrations, :integration_type, false
  end
end
