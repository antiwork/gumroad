# frozen_string_literal: true

class EmailRedactorService
  def self.redact(email)
    username, domain = email.split("@")
    domain_name, _, tld = domain.rpartition(".")

    redacted_username = username.length > 1 ? "#{username[0]}#{'*' * (username.length - 2)}#{username[-1]}" : username
    redacted_domain = "#{domain_name[0]}#{'*' * (domain_name.length - 1)}"

    "#{redacted_username}@#{redacted_domain}.#{tld}"
  end
end
