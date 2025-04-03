# frozen_string_literal: true

class UsernameGeneratorService
  attr_reader :user

  def initialize(user)
    @user = user
  end

  def username
    return if user_data.nil?

    name = ensure_valid_username(openai_completion)
    name += random_digit while User.exists?(username: name)
    return if name.length > 20

    name
  end

  private
    def openai_completion
      response = OpenAI::Client.new.chat(parameters: { messages: [{ role: "user", content: prompt }],
                                                       model: "gpt-4o-mini",
                                                       temperature: 0.0,
                                                       max_tokens: 10 })
      response.dig("choices", 0, "message", "content").strip
    end

    # Although very unlikely, in theory OpenAI could return a username that is invalid
    # This method ensures that the username meets our validation criteria:
    # 1. Only lowercase letters and numbers
    # 2. At least one letter
    # 3. Not in DENYLIST
    # 4. Between 3 and 20 characters
    def ensure_valid_username(name)
      name = name.downcase.gsub(/[^a-z0-9]/, "")
      name += "a" if name.blank? || name.match?(/^[0-9]+$/)
      name += random_digit if DENYLIST.include?(name)
      name += random_digit while name.length < 3
      name.first(20)
    end

    def random_digit
      SecureRandom.random_number(9).to_s
    end

    def prompt
      "Generate a username for a user with #{user_data}. It should be one word and all lowercase with no numbers. Avoid any generic sounding names like #{bad_usernames.join(", ")}."
    end

    def user_data
      if user.email.present?
        "the email address #{user.email}. DO NOT use the email domain if it's a generic email provider"
      elsif user.name.present?
        "the name #{user.name}"
      end
    end

    def bad_usernames
      %w[support hi hello contact info help]
    end
end
