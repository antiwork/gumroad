# frozen_string_literal: true

# GlobalConfig provides a centralized way to access environment variables and Rails credentials
class GlobalConfig
  class << self
    # Retrieve a value by its name from environment variables or Rails credentials
    # @param name [String] The name of the environment variable
    # @param default [Object] The default value to return if the value is not found in ENV or credentials
    # @return [String, Object, nil] The value from environment variable, credentials, the default value, or nil if not found and no default provided
    def get(name, default = :__no_default_provided__)
      if default == :__no_default_provided__
        value = ENV.fetch(name, fetch_from_credentials(name))
        value.presence
      else
        ENV.fetch(name, fetch_from_credentials(name) || default)
      end
    end

    # Retrieve a nested value by joining the parts with double underscores
    # @param parts [Array<String>] The parts to join for the environment variable name
    # @param default [Object] The default value to return if the value is not found
    # @return [String, Object, nil] The value from environment variable, credentials, the default value, or nil if not found and no default provided
    def dig(*parts, default: :__no_default_provided__)
      name = parts.map(&:upcase).join("__")
      if default == :__no_default_provided__
        get(name)
      else
        get(name, default)
      end
    end

    private
      # Fetch a value from Rails credentials by converting the environment variable name to credential keys
      # @param name [String] The name of the environment variable
      # @return [Object, nil] The value from credentials or nil if not found
      def fetch_from_credentials(name)
        keys = name.downcase.split("__").map(&:to_sym)
        Rails.application.credentials.dig(*keys)
      end
  end
end
