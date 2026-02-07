#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'optparse'
require 'time'

SCRIPT_NAME = 'verify/torture'
ROOT_DIR = File.expand_path('..', __dir__)
VERIFY_DIR = File.join(ROOT_DIR, 'verify')
LOG_ROOT = File.join(VERIFY_DIR, 'logs')

DEFAULT_DURATION_SECONDS = 3600
DEFAULT_SLEEP_SECONDS = 3
DEFAULT_SCRIPT_TIMEOUT_SECONDS = 720

SCRIPT_TIMEOUT_OVERRIDES = {
  'active_scan.rb' => 60,
  'passive_scan.rb' => 180,
  'connect.rb' => 180,
  'subscribe.rb' => 180,
  'stream.rb' => 720
}.freeze

def parse_args
  options = {
    duration_seconds: DEFAULT_DURATION_SECONDS,
    sleep_seconds: DEFAULT_SLEEP_SECONDS,
    script_timeout_seconds: DEFAULT_SCRIPT_TIMEOUT_SECONDS,
    seed: nil
  }

  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby verify/torture.rb [options]'

    opts.on('-d', '--duration SECONDS', Integer, 'Total run duration (default: 3600)') do |v|
      options[:duration_seconds] = v
    end

    opts.on('-s', '--sleep SECONDS', Float, 'Delay between scripts (default: 3)') do |v|
      options[:sleep_seconds] = v
    end

    opts.on('-t', '--script-timeout SECONDS', Integer, 'Per-script timeout (default: 720)') do |v|
      options[:script_timeout_seconds] = v
    end

    opts.on('--seed N', Integer, 'Random seed for reproducible ordering') do |v|
      options[:seed] = v
    end

    opts.on('-h', '--help', 'Print help') do
      puts opts
      exit 0
    end
  end.parse!

  raise OptionParser::InvalidArgument, 'duration must be > 0' if options[:duration_seconds] <= 0
  raise OptionParser::InvalidArgument, 'sleep must be >= 0' if options[:sleep_seconds] < 0
  raise OptionParser::InvalidArgument, 'script-timeout must be > 0' if options[:script_timeout_seconds] <= 0

  options
end

def discover_scripts
  excluded = %w[torture.rb reason_codes.rb]
  Dir.glob(File.join(VERIFY_DIR, '*.rb'))
     .sort
     .reject { |path| excluded.include?(File.basename(path)) }
end

def parse_script_status(output, exit_status)
  status_match = output.match(/^Status:\s+(PASS|FAIL|SKIP)\b/m)
  return status_match[1] if status_match

  return 'TIMEOUT' if exit_status == 124
  return 'PASS' if exit_status.zero?

  'FAIL'
end

def parse_script_reason(output)
  output[/^Reason:\s+([A-Z0-9_]+)/m, 1]
end

def format_seconds(seconds)
  total = seconds.to_i
  h = total / 3600
  m = (total % 3600) / 60
  s = total % 60
  format('%02d:%02d:%02d', h, m, s)
end

def build_stats(scripts)
  stats = {}
  scripts.each do |script|
    stats[script] = {
      runs: 0,
      pass: 0,
      fail: 0,
      skip: 0,
      timeout: 0,
      total_duration: 0.0,
      reasons: Hash.new(0)
    }
  end
  stats
end

def update_stats(stats, script, status, duration, reason = nil)
  row = stats.fetch(script)
  row[:runs] += 1
  row[:total_duration] += duration
  row[:reasons][reason] += 1 if reason

  case status
  when 'PASS' then row[:pass] += 1
  when 'SKIP' then row[:skip] += 1
  when 'TIMEOUT' then row[:timeout] += 1
  else row[:fail] += 1
  end
end

def run_script_once(script, timeout_seconds)
  command = [
    'timeout',
    '--signal=TERM',
    '--kill-after=10',
    timeout_seconds.to_s,
    'ruby',
    script
  ]

  run_started = Time.now
  output, status = Open3.capture2e(*command, chdir: ROOT_DIR)
  run_duration = Time.now - run_started
  exit_code = status.exitstatus
  parsed_status = parse_script_status(output, exit_code)
  parsed_status = 'TIMEOUT' if exit_code == 124

  {
    output: output,
    duration: run_duration,
    exit_code: exit_code,
    status: parsed_status
  }
end

def timeout_for_script(script, options)
  SCRIPT_TIMEOUT_OVERRIDES.fetch(File.basename(script), options[:script_timeout_seconds])
end

def print_timeout_plan(script_timeouts)
  puts '-' * 72
  puts 'Per-script timeout plan:'
  script_timeouts.sort.each do |script, timeout_seconds|
    script_name = script.sub("#{ROOT_DIR}/", '')
    puts format('  %-30s %4ds', script_name, timeout_seconds)
  end
end

def print_final_summary(start_time, end_time, stats, log_dir, options)
  elapsed = end_time - start_time
  total_runs = stats.values.sum { |r| r[:runs] }
  total_pass = stats.values.sum { |r| r[:pass] }
  total_fail = stats.values.sum { |r| r[:fail] }
  total_skip = stats.values.sum { |r| r[:skip] }
  total_timeout = stats.values.sum { |r| r[:timeout] }

  puts
  puts '=' * 72
  puts 'TORTURE TEST SUMMARY'
  puts '-' * 72
  puts "Started:      #{start_time.iso8601}"
  puts "Finished:     #{end_time.iso8601}"
  puts "Elapsed:      #{format_seconds(elapsed)}"
  puts "Target:       #{format_seconds(options[:duration_seconds])}"
  puts "Runs:         #{total_runs}"
  puts "PASS/SKIP:    #{total_pass}/#{total_skip}"
  puts "FAIL/TIMEOUT: #{total_fail}/#{total_timeout}"
  puts "Logs:         #{log_dir}"
  puts '-' * 72
  puts format('%-22s %6s %6s %6s %8s %8s %8s', 'Script', 'Runs', 'PASS', 'SKIP', 'FAIL', 'TIMEOUT', 'AVG(s)')
  puts '-' * 72

  stats.sort_by { |path, _| path }.each do |path, row|
    script_name = path.sub("#{ROOT_DIR}/", '')
    avg = row[:runs].zero? ? 0.0 : (row[:total_duration] / row[:runs])
    puts format('%-22s %6d %6d %6d %8d %8d %8.1f',
                script_name,
                row[:runs],
                row[:pass],
                row[:skip],
                row[:fail],
                row[:timeout],
                avg)
  end

  reason_totals = Hash.new(0)
  stats.each_value do |row|
    row[:reasons].each { |reason, count| reason_totals[reason] += count }
  end

  unless reason_totals.empty?
    puts '-' * 72
    puts 'Reason codes:'
    reason_totals.sort_by { |_, count| -count }.each do |reason, count|
      puts format('  %-40s %4d', reason, count)
    end
  end

  puts '=' * 72
end

def run
  options = parse_args
  srand(options[:seed]) if options[:seed]

  scripts = discover_scripts
  if scripts.empty?
    warn 'ERROR: no verify scripts found to run'
    exit 1
  end

  timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
  log_dir = File.join(LOG_ROOT, "torture-#{timestamp}")
  FileUtils.mkdir_p(log_dir)

  start_time = Time.now
  deadline = start_time + options[:duration_seconds]
  stats = build_stats(scripts)
  iteration = 0
  queue = []
  script_timeouts = scripts.each_with_object({}) { |script, memo| memo[script] = timeout_for_script(script, options) }

  puts "Starting #{SCRIPT_NAME}"
  puts "Duration target: #{format_seconds(options[:duration_seconds])}"
  puts "Fallback timeout: #{options[:script_timeout_seconds]}s"
  puts "Inter-script sleep: #{options[:sleep_seconds]}s"
  puts "Scripts in mix: #{scripts.map { |s| File.basename(s) }.join(', ')}"
  puts "Logs: #{log_dir}"

  print_timeout_plan(script_timeouts)
  puts '-' * 72

  while Time.now < deadline
    queue = scripts.shuffle if queue.empty?
    script = queue.shift
    iteration += 1

    remaining_before = (deadline - Time.now).round(1)
    script_name = script.sub("#{ROOT_DIR}/", '')
    puts "[#{iteration}] START #{script_name} (remaining #{remaining_before}s)"

    result = run_script_once(script, script_timeouts.fetch(script))
    reason = parse_script_reason(result[:output])
    update_stats(stats, script, result[:status], result[:duration], reason)

    log_path = File.join(log_dir, format('%04d-%s.log', iteration, File.basename(script, '.rb')))
    File.write(log_path, result[:output])

    puts "[#{iteration}] END   #{script_name} => #{result[:status]} (#{result[:duration].round(1)}s, exit #{result[:exit_code]})"
    puts "            reason: #{reason}" if reason
    puts "            log: #{log_path}"

    sleep_time = [options[:sleep_seconds], deadline - Time.now].min
    sleep(sleep_time) if sleep_time.positive?
  end

  end_time = Time.now
  print_final_summary(start_time, end_time, stats, log_dir, options)

  total_failures = stats.values.sum { |r| r[:fail] + r[:timeout] }
  exit(total_failures.zero? ? 0 : 1)
end

run
