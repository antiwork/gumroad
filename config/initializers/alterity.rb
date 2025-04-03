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

  # Notify team of migrations running, on a best-effort basis, synchronously.
  # Only for production and main staging environments.
  send_slack_message = Rails.env.production? || (Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"].blank?)

  config.before_command = lambda do |command|
    next unless send_slack_message
    command_clean = command.gsub(/.* (D=.*)/, "\\1").gsub("\\`", "")
    SlackMessageWorker.new.perform("migrations", "Web", "*[#{Rails.env}] Will execute migration:* #{command_clean}")
  rescue => _
  end

  config.on_command_output = lambda do |output|
    next unless send_slack_message
    output.strip!
    next if output.blank?
    next if output.in?([ # needless log of configuration from PT-OSC
                         "Operation, tries, wait:",
                         "analyze_table, 10, 1",
                         "copy_rows, 10, 0.25",
                         "create_triggers, 10, 1",
                         "drop_triggers, 10, 1",
                         "swap_tables, 10, 1",
                         "update_foreign_keys, 10, 1",
                       ])
    SlackMessageWorker.new.perform("migrations", "Web", output)
  rescue => _
  end

  config.after_command = lambda do |exit_status|
    next unless send_slack_message
    color = exit_status == 0 ? "green" : "red"
    SlackMessageWorker.new.perform("migrations", "Web", "Command exited with status #{exit_status}", color)
  rescue => _
  end
end
