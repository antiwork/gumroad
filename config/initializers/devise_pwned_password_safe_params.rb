# frozen_string_literal: true

# devise-pwned_password does params.fetch(scope, {}).fetch(:password, nil).
# Skip unless scoped params are a Hash — OAuth has no password to check.
Warden::Manager._after_set_user.each do |pair|
  block, _conditions = pair
  next unless block.source_location&.first&.include?("devise/pwned_password/hooks/pwned_password")

  pair[0] = lambda do |user, auth, opts|
    scoped = auth.request.params[opts[:scope]]
    next unless scoped.is_a?(Hash)

    block.call(user, auth, opts)
  end
end
