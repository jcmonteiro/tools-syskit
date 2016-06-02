require "bundler/gem_tasks"
require "rake/testtask"

task :default

Rake::TestTask.new(:test) do |t|
    t.libs << "."
    t.libs << "lib"
    t.test_files = FileList['test/suite.rb']
    t.warning = false
end

begin
    require 'coveralls/rake/task'
    Coveralls::RakeTask.new
    task 'test:coveralls' => ['test', 'coveralls:push']
rescue LoadError
end

# For backward compatibility with some scripts that expected hoe
task :gem => :build

