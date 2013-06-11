# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ar_database_duplicator/version'

Gem::Specification.new do |spec|
  spec.name          = "ar_database_duplicator"
  spec.version       = ArDatabaseDuplicator::VERSION
  spec.authors       = ["Frank Hall"]
  spec.email         = ["ChapterHouse.Dune@gmail.com"]
  spec.description   = %q{Duplicate a complete or partial database with ActiveRecord while controlling sensitive values.}
  spec.summary       = %q{Duplicate a complete or partial database with ActiveRecord while controlling sensitive values.}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency 'mocha'
  spec.add_development_dependency "shoulda"
  spec.add_development_dependency 'minitest'
  spec.add_development_dependency 'minitest-reporters'


  spec.add_runtime_dependency "pseudo_entity", ">= 0.0.4"
  spec.add_runtime_dependency "ruby-progressbar", "~> 1.0"
  spec.add_runtime_dependency "activerecord", ">= 2.3"
  spec.add_runtime_dependency "sqlite3"


end

