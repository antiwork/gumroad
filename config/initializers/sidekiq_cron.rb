# frozen_string_literal: true

Sidekiq.configure_server do |config|
  config.on(:startup) do
    sidekiq_schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
    Sidekiq::Cron::Job.load_from_hash!(sidekiq_schedule, source: "schedule")
  end
end
