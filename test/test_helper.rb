$LOAD_PATH << File.join(File.dirname(__FILE__), '..', 'lib')
require 'ar_database_duplicator'
require 'test/unit'
require 'minitest/autorun'
require 'shoulda'
require 'mocha/setup'



def remove_duplications
  directory = Rails.root + "db" + "duplication"
  FileUtils.remove_entry_secure(directory) if File.exist?(directory)
end

