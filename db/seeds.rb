# frozen_string_literal: true

def seed_log(msg)
  puts msg unless Rails.env.test?
end

def load_seeds(file)
  seed_log "Applying seeds in: #{file}"
  load(file, true)
end

seed_log "Applying seeds for environment: #{Rails.env}"

# Load common seeds.
common_directory = __dir__ + "/seeds"
Dir[File.join(common_directory, "*.rb")].sort.each { |file| load_seeds(file) }

# Load environment specific seeds.
# Each subdirectory can contain seeds for one or more environments.
# The subdirectory name is an underscore delimited list of environment names it applies to.
environment_dirs = Dir["#{common_directory}/*/"].sort
environment_dirs.each do |environment_dir|
  environment_dir_name = File.basename(environment_dir)

  # If the directory name contains the environment, load seeds in that directory.
  Dir[File.join(environment_dir, "*.rb")].each { |file| load_seeds(file) } if /(^|_)#{Regexp.escape(Rails.env)}(_|$)/.match?(environment_dir_name)
end
