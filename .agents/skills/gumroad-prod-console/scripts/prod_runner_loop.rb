# Persistent query loop for prod_query.sh. Booted once via `rails runner`,
# then serves spooled queries without paying Rails boot per call.
#
# Contract with prod_query.sh: jobs arrive as #{id}.rb files in in/, results
# leave as out/#{id}.out + out/#{id}.rc, both renamed into place only when
# complete so the shell never reads a partial file.
require "fileutils"
require "timeout"

BASE = ENV.fetch("GUMCLAW_RUNNER_DIR", "/tmp/gumclaw-runner")
IN_DIR = File.join(BASE, "in")
OUT_DIR = File.join(BASE, "out")
PID_FILE = File.join(BASE, "loop.pid")
IDLE_LIMIT = Integer(ENV.fetch("GUMCLAW_RUNNER_IDLE_LIMIT", "1800"))
JOB_LIMIT = Integer(ENV.fetch("GUMCLAW_RUNNER_JOB_LIMIT", "300"))

FileUtils.mkdir_p(IN_DIR)
FileUtils.mkdir_p(OUT_DIR)

if File.exist?(PID_FILE)
  old = begin; Integer(File.read(PID_FILE).strip); rescue StandardError; 0; end
  if old.positive? && (begin; Process.kill(0, old); true; rescue StandardError; false; end)
    exit 0
  end
end
File.write(PID_FILE, Process.pid.to_s)

last_job = Time.now
loop do
  job = Dir[File.join(IN_DIR, "*.rb")].min
  if job.nil?
    break if Time.now - last_job > IDLE_LIMIT
    sleep 0.2
    next
  end
  last_job = Time.now
  id = File.basename(job, ".rb")
  code = File.read(job)
  # Taken marker BEFORE deleting the job: the client must be able to tell
  # "never picked up" (safe to re-run one-shot) from "executed or executing"
  # (must not re-run) at every instant.
  FileUtils.touch(File.join(OUT_DIR, "#{id}.taken"))
  File.delete(job)
  out_path = File.join(OUT_DIR, "#{id}.out")
  err_path = File.join(OUT_DIR, "#{id}.err")
  rc_path = File.join(OUT_DIR, "#{id}.rc")

  # Fork per query: leaked state or a hard crash cannot poison the booted
  # parent, and each child opens fresh DB connections (shared post-fork
  # sockets corrupt the MySQL protocol).
  ActiveRecord::Base.connection_handler.clear_all_connections!
  child = fork do
    $stdout.reopen(File.open("#{out_path}.tmp", "w"))
    $stderr.reopen(File.open("#{err_path}.tmp", "w"))
    # AR is cleared pre-fork, but the boot-time $redis client still holds the
    # parent's socket; concurrent use across forks corrupts its protocol the
    # same way it does MySQL's. Closing forces a clean reconnect on next use.
    begin
      $redis&.close
    rescue StandardError
      nil
    end
    status = 0
    begin
      Timeout.timeout(JOB_LIMIT) { eval(code, TOPLEVEL_BINDING) } # rubocop:disable Security/Eval
    rescue SystemExit => e
      status = e.status
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "#{e.class}: #{e.message}"
      e.backtrace&.first(10)&.each { |line| warn line }
      status = 1
    end
    $stdout.flush
    $stderr.flush
    File.write("#{rc_path}.tmp", status.to_s)
    exit!(status)
  end
  _, wait_status = Process.wait2(child)
  File.write("#{rc_path}.tmp", (wait_status.exitstatus || 1).to_s) unless File.exist?("#{rc_path}.tmp")
  FileUtils.mv("#{out_path}.tmp", out_path) if File.exist?("#{out_path}.tmp")
  FileUtils.mv("#{err_path}.tmp", err_path) if File.exist?("#{err_path}.tmp")
  FileUtils.mv("#{rc_path}.tmp", rc_path)
end

begin
  File.delete(PID_FILE) if Integer(File.read(PID_FILE).strip) == Process.pid
rescue StandardError
  nil
end
