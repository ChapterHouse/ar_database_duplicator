require "bundler/gem_tasks"

require 'rake/testtask'

Rake::TestTask.new do |t|
  t.libs << 'test/lib'
  t.test_files = FileList['test/lib/*test.rb']
end

desc "Run tests"
task :default => :test