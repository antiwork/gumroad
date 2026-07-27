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
      --preserve-triggers
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

    # Refuse the schema change if this table still carries the triggers and shadow
    # table of an earlier pt-online-schema-change that was abandoned without cleanup.
    #
    # pt-osc derives its trigger names from the database and table name with nothing
    # to make them unique per run, so leftovers from one abandoned run make every
    # later run on that table fail on "Trigger already exists" — in seconds, and
    # without leaving any trace in the database. Failing here instead names the
    # leftover artifacts and says what has to be cleared, rather than surfacing a
    # bare MySQL error that describes the symptom. See PtOscLeftoverCheck and
    # gumroad-private#1417.
    #
    # The table name is recovered from the command Alterity built, which is the only
    # place the hook can see it. It has to be matched as the whole `D=<db>,t=<table>`
    # argument, not a bare `t=`: the command also carries
    # `--recursion-method 'dsn=D=percona,t=replicas_dsns'`, which appears EARLIER, so a
    # loose match reads the replica-DSN bookkeeping table instead of the table being
    # altered — and then happily reports it clean while the real table is blocked.
    #
    # The database part is allowed to be empty. Alterity only populates it in
    # before_running_migrations, so a command built outside a migration run reads
    # `D=,t=<table>` — and the table name, which is all this needs, is still there.
    #
    # If that parse ever fails to find a table (a command template change), the check
    # is skipped rather than guessed at: blocking a migration on a table we could not
    # identify would be worse than not checking.
    table = command[/(?:\A|\s)D=[^\s,]*,t=([^\s,]+)/, 1]
    PtOscLeftoverCheck.assert_absent!(table) if table.present?
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
