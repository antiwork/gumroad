# frozen_string_literal: true

if defined?(PryByebug)
  Pry.commands.alias_command "c", "continue"
  Pry.commands.alias_command "s", "step"
  Pry.commands.alias_command "n", "next"
  Pry.commands.alias_command "f", "finish"
  Pry.commands.alias_command "bt", "pry-backtrace"

  Pry.config.editor = "vim"
  Pry.config.pager = false
end
