# frozen_string_literal: true

Alterity.configure do |config|
  config.command = -> (altered_table, alter_argument) {
    password_argument = "--password='#{config.password}'" if config.password.present?
    <<~SHELL.squish
    pt-online-schema-change
      -h #{config.host}
      -P #{config.port}
      -u #{config.username}
      #{password_argument}
      --nocheck-replication-filters
      --critical-load Threads_running=1000
      --max-load Threads_running=200
      --set-vars lock_wait_timeout=1
      --recursion-method 'dsn=D=#{config.replicas_dsns_database},t=#{config.replicas_dsns_table}'
      --execute
      --no-check-alter
      D=#{config.database},t=#{altered_table}
      --alter #{alter_argument}
    SHELL
  }

  config.replicas(
    database: "percona",
    table: "replicas_dsns",
    dsns: REPLICAS_HOSTS
  )

  config.before_command = lambda do |command|
    command_clean = command.gsub(/.* (D=.*)/, "\\1").gsub("\\`", "")
    Rails.logger.info("[Alterity] [#{Rails.env}] Will execute migration: #{command_clean}")
  end

  config.on_command_output = lambda do |output|
    output.strip!
    next if output.blank?
    next if output.in?(["Operation, tries, wait:",
                        "analyze_table, 10, 1",
                        "copy_rows, 10, 0.25",
                        "create_triggers, 10, 1",
                        "drop_triggers, 10, 1",
                        "swap_tables, 10, 1",
                        "update_foreign_keys, 10, 1"])
    Rails.logger.info("[Alterity] #{output}")
  end

  config.after_command = lambda do |exit_status|
    Rails.logger.info("[Alterity] Command exited with status #{exit_status}")
  end
end
