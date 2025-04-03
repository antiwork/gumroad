# frozen_string_literal: true

module SecureHeadersHelpers
  def set_nonce_in_script_src_csp(nonce_value)
    new_config = SecureHeaders::Configuration.dup
    new_config.csp.script_src << "'nonce-#{nonce_value}'"
    SecureHeaders::Configuration.instance_variable_set("@default_config", new_config)
  end

  def remove_nonce_from_script_src_csp(nonce_value)
    new_config = SecureHeaders::Configuration.dup
    new_config.csp.script_src.delete("'nonce-#{nonce_value}'") if new_config.csp.respond_to?(:script_src)
    SecureHeaders::Configuration.instance_variable_set("@default_config", new_config)
  end
end
