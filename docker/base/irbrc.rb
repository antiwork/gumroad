# frozen_string_literal: true

if ENV["RAILS_ENV"] == "production"
  original_prompt = IRB.conf[:PROMPT][:DEFAULT][:PROMPT_I]
  new_prompt = "\033[33mPRODUCTION \033[m" + original_prompt

  IRB.conf[:PROMPT][:DEFAULT][:PROMPT_I] = new_prompt
end
