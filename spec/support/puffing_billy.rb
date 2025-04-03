# frozen_string_literal: true

# From https://knapsackpro.com/faq/question/how-to-configure-puffing-billy-gem-with-knapsack-pro-queue-mode
# A patch to `puffing-billy`'s proxy so that it doesn't try to stop
# eventmachine's reactor if it's not running.
module BillyProxyPatch
  def stop
    return unless EM.reactor_running?
    super
  end
end
Billy::Proxy.prepend(BillyProxyPatch)

# A patch to `puffing-billy` to start EM if it has been stopped
Billy.module_eval do
  def self.proxy
    if @billy_proxy.nil? || !(EventMachine.reactor_running? && EventMachine.reactor_thread.alive?)
      proxy = Billy::Proxy.new
      proxy.start
      @billy_proxy = proxy
    else
      @billy_proxy
    end
  end
end

KnapsackPro::Hooks::Queue.before_queue do
  # executes before Queue Mode starts work
  Billy.proxy.start
end

KnapsackPro::Hooks::Queue.after_queue do
  # executes after Queue Mode finishes work
  Billy.proxy.stop
end
