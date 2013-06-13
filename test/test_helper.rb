$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')
require 'ar_database_duplicator'
require 'test/unit'
require 'minitest/autorun'
require 'minitest/reporters'
require 'shoulda'
require 'mocha/setup'

MiniTest::Reporters.use!

ActiveRecord::Migration.verbose = false

class Rails
  def self.root
    Pathname.new(__FILE__).parent
  end
end unless Object.const_defined?(:Rails)


def remove_duplications
  directory = Rails.root + "db" + "duplication"
  FileUtils.remove_entry_secure(directory) if File.exist?(directory)
end

