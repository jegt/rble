# frozen_string_literal: true

# Load all RBLE rake tasks
# Usage in Rakefile: require 'rble/tasks'

Dir.glob(File.join(__dir__, 'tasks', '*.rake')).each do |task_file|
  load task_file
end
