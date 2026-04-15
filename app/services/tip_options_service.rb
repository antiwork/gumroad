# frozen_string_literal: true

class TipOptionsService
  DEFAULT_TIP_OPTIONS = [0, 15, 20, 25]
  DEFAULT_DEFAULT_TIP_OPTION = 0

  def self.get_tip_options
    options = $redis.get(RedisKey.tip_options)
    parsed_options = options ? JSON.parse(options) : DEFAULT_TIP_OPTIONS
    are_tip_options_valid?(parsed_options) ? parsed_options : DEFAULT_TIP_OPTIONS
  rescue
    DEFAULT_TIP_OPTIONS
  end

  def self.set_tip_options(options)
    raise ArgumentError, "Tip options must be an array of integers" unless are_tip_options_valid?(options)
    $redis.set(RedisKey.tip_options, options.to_json)
  end

  def self.get_default_tip_option
    option = $redis.get(RedisKey.default_tip_option)&.to_i || DEFAULT_DEFAULT_TIP_OPTION
    is_default_tip_option_valid?(option) ? option : DEFAULT_DEFAULT_TIP_OPTION
  end

  def self.set_default_tip_option(option)
    raise ArgumentError, "Default tip option must be an integer" unless is_default_tip_option_valid?(option)
    $redis.set(RedisKey.default_tip_option, option)
  end

  private
    def self.are_tip_options_valid?(options)
      options.is_a?(Array) && options.all? { |o| o.is_a?(Integer) }
    end

    def self.is_default_tip_option_valid?(option)
      option.is_a?(Integer)
    end
end
