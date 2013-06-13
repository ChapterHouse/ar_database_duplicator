require File.dirname(__FILE__) + "/../test_helper"
require 'fileutils'
#require 'ar_database_duplicator'
#
class TestClass < ActiveRecord::Base
  COLUMN_NAMES =  ["safe", "temp_safe", "unsafe", "instance_safe", "changed"]

  def self.column_names
    COLUMN_NAMES
  end

  def initialize
  end

end

class ARDatabaseDuplicatorTest < Test::Unit::TestCase
  context "instance" do

    context "public methods" do

      setup do
        Dir.chdir(Rails.root)
        @db = ARDatabaseDuplicator.new(:source => "test_source", :destination => "test_destination")
        ARDatabaseDuplicator.send(:public, :destination_directory_exists?)
      end

      teardown do
        remove_duplications
      end

      should "call use_connection in use_source" do
        @db.expects("use_connection").with(@db.source, "subname")
        @db.use_source("subname")
      end

      should "call use_connection in use_destination" do
        @db.expects("use_connection").with(@db.destination, "subname")
        @db.use_destination("subname")
      end

      should "not allow destination=production" do
        assert_raises(ArgumentError) do
          @db.destination = "production"
        end
      end

      should "set destination_directory_exists? to false after setting destination" do
        @db.instance_variable_set(:@destination_directory_exists, true)
        @db.destination = "staging"
        assert !@db.destination_directory_exists?
        assert_equal "staging", @db.destination
      end

      should "set destination_directory_exists? to false after setting split_data" do
        @db.instance_variable_set(:@destination_directory_exists, true)
        @db.split_data = true
        assert !@db.destination_directory_exists?
        assert @db.split_data
      end

      #TODO: tests for load_duplication

      should "ensure SchemaMigration is defined" do
        @db.stubs(:load_schema_split)
        @db.stubs(:load_schema_combined)
        Object.send(:remove_const, :SchemaMigration) if Object.const_defined?(:SchemaMigration)
        assert !Object.const_defined?(:SchemaMigration)
        @db.load_schema
        assert Object.const_defined?(:SchemaMigration)
      end

      should "call load_schema_split when split_data? is true" do
        @db.stubs(:load_schema_split)
        @db.stubs(:load_schema_combined)
        @db.split_data = true
        @db.expects(:load_schema_split)
        @db.load_schema
      end

      should "call load_schema_combined when split_data? is false" do
        @db.stubs(:load_schema_split)
        @db.stubs(:load_schema_combined)
        @db.split_data = false
        @db.expects(:load_schema_combined)
        @db.load_schema
      end

      should "define AR when for the given name" do
        Object.send(:remove_const, "Something") if Object.const_defined?("Something")
        @db.define_class("something")
        assert Object.const_defined?("Something")
        assert(Something < ActiveRecord::Base)
      end

      #TODO: tests for duplicate

      should "call with_connection using source in with_source" do
        @db.expects("with_connection").with(@db.source, "subname", true)
        @db.with_source("subname", true) {}
      end

      should "call with_connection using destination in with_destination" do
        @db.expects("with_connection").with(@db.destination, "subname", true)
        @db.with_destination("subname", true) {}
      end

    end

    context "private methods" do

      setup do
        #@db = ARDatabaseDuplicator.new(:schema_file => Rails.root + 'test/fixtures/files/sample_schema.rb')
        Dir.chdir(Rails.root)
        @db = ARDatabaseDuplicator.new(:schema_file => "db/sample_schema.rb", :source => "test_source", :destination => "test_destination")


        #@db = ARDatabaseDuplicator.new(:schema_file => 'test/fixtures/files/sample_schema.rb')
        #@db.stubs(:use_spec)
        ARDatabaseDuplicator.send(:public, :destination_directory)
        ARDatabaseDuplicator.send(:public, :load_schema_combined)
        ARDatabaseDuplicator.send(:public, :load_schema_split)
        ARDatabaseDuplicator.send(:public, :replace_attributes)
        ARDatabaseDuplicator.send(:public, :replace)
        ARDatabaseDuplicator.send(:public, :replace_with)
        ARDatabaseDuplicator.send(:public, :set_temporary_vetted_attributes)
        ARDatabaseDuplicator.send(:public, :transfer)
        ARDatabaseDuplicator.send(:public, :already_duplicated?)
        ARDatabaseDuplicator.send(:public, :schema_loaded?)
        ARDatabaseDuplicator.send(:public, :singleton?)
        ARDatabaseDuplicator.send(:public, :block_required?)
        ARDatabaseDuplicator.send(:public, :use_connection)
        ARDatabaseDuplicator.send(:public, :use_spec)
        ARDatabaseDuplicator.send(:public, :with_connection)

        ARDatabaseDuplicator.send(:public, :base_path)
        ARDatabaseDuplicator.send(:public, :entity)
      end

      teardown do
        remove_duplications
      end

      context "replace" do
        setup do
          @db.stubs(:replace_with)
        end

        should "get the replacement value from PseudoEntity if the value is a symbol" do
          first_name = @db.entity.first_name
          @db.entity.instance_eval <<-EOF
            alias :first_name_original :first_name
          EOF
          @db.entity.expects(:first_name).once.returns(@db.entity.first_name_original)
          assert @db.expects(:replace_with).with(nil, "something", first_name)
          @db.replace(nil, {"something" => :first_name})
        end

        should "raise an exception if the entity does not respond to the symbol value" do
          assert_raises(RuntimeError) do
            @db.replace(nil, {"something" => :doesnt_exist})
          end
        end

        should "not call on PseudoEntity if the value is not a symbol" do
          @db.entity.expects(:first_name).never
          assert @db.expects(:replace_with).with(nil, "something", "first_name")
          @db.replace(nil, {"something" => "first_name"})
        end

        should "call the original PseudoEntity method when encryption is asked for" do
          first_name = @db.entity.first_name
          @db.entity.instance_eval <<-EOF
            alias :first_name_original :first_name
          EOF
          @db.entity.expects(:first_name).once.returns(@db.entity.first_name_original)
          assert @db.expects(:replace_with).with(nil, "something", first_name.encrypt(:key => "1234"))
          @db.replace(nil, {"something" => :encrypted_first_name})
        end

        should "set iv and salt if the target responds to them for encrypted values" do
          @db = ARDatabaseDuplicator.new
          first_name = @db.entity.first_name
          object = Object.new
          class << object
            def first_name
              @first_name ||= "a"
            end
            def first_name_salt
              @first_name_salt ||= "a"
            end
            def first_name_iv
              @first_name_iv ||= "a"
            end
            def first_name=(x)
              @first_name = x
            end
            def first_name_salt=(x)
              @first_name_salt = x
            end
            def first_name_iv=(x)
              @first_name_iv = x
            end
          end
          @db.replace(object, {:first_name => :encrypted_first_name})
          assert_not_equal 1, object.first_name_salt, "Salt was not set"
          assert_not_equal 1,  object.first_name_iv, "Initialization vector was not set"
          assert_equal first_name.encrypt(:key => "1234", :iv => object.first_name_iv, :salt => object.first_name_salt), object.first_name
        end


      end

      context "replace_attributes" do
        setup do
          @db.stubs(:replace)
        end

        should "call entity.reset! once before replace" do
          name = @db.entity.first_name
          other_name = name

          singleton_klass = class << @db; self; end
          singleton_klass.send(:define_method, :replace) { |*args|
            other_name = entity.first_name
          }

          @db.replace_attributes(nil, [{:a => 1}])
          assert name != other_name, "entity.reset! was not called before replace"
        end

        should "not call replace when replacement_hash empty" do
          @db.expects(:replace).never()
          @db.replace_attributes(nil, [{}])
        end

        should "yield entity when block given with arity==1" do
          name = @db.entity.first_name
          @db.replace_attributes(nil, []) do |x|
            assert x.is_a?(PseudoEntity)
            assert x.first_name != name
          end
        end

        should "yield entity, record when block given with arity != 1" do
          name = @db.entity.first_name
          @db.replace_attributes("abc", []) do |x, y|
            assert x.is_a?(PseudoEntity)
            assert x.first_name != name
            assert_equal "abc", y
          end
        end

        should "call replace if block returns a hash" do
          @db.expects(:replace).once()
          @db.replace_attributes(nil, []) { |x| {:a => 1} }
        end

        should "not call replace if block does not return a hash" do
          @db.expects(:replace).never()
          @db.replace_attributes(nil, []) { |x| nil }
        end
      end

      context "#destination_directory" do

        should "use only the base_path if split_data is false" do
          @db.split_data = false
          assert_equal @db.base_path, @db.destination_directory
        end

        should "use the base_path and the destination if split_data is true" do
          @db.split_data = true
          assert_equal (@db.base_path + @db.destination), @db.destination_directory
        end

      end

      context "#load_schema_combined" do

        setup do
          @db.load_schema_combined
        end

        should "migrate the schema" do
          @db.with_destination do
            @db.define_class('SchemaMigration')
            assert SchemaMigration.table_exists?, "SchemaMigration table does not exist"
            assert_operator SchemaMigration.count, :>, 0
          end
        end

        should "create the table schema" do
          @db.with_destination do
            @db.define_class('TableSchema')
            assert TableSchema.table_exists?, "TableSchema table does not exist"
            assert_operator TableSchema.count, :>, 0
          end
        end

        should "store the schema for each table" do
          @db.with_destination do
            captured_schema = ARDatabaseDuplicator::CapturedSchema.new(@db, @db.schema_file)
            captured_schema.table_names.each do |table_name|
              table_schema = TableSchema.find(:first, :conditions => {:table_name => table_name})
              assert table_schema, "Missing table schema for #{table_name}"
              assert_equal captured_schema.schema_for(table_name), table_schema.schema
            end
          end
        end

      end


      context "#load_schema_split" do

        setup do
          @db.load_schema_split
          @captured_schema = ARDatabaseDuplicator::CapturedSchema.new(@db, @db.schema_file)
        end

        should "migrate the schema" do
          @captured_schema.table_names.each do |table_name|
            @db.with_destination(table_name, true) do
              @db.define_class('SchemaMigration')
              assert SchemaMigration.table_exists?, "SchemaMigration table does not exist in #{table_name}"
              assert_operator SchemaMigration.count, :>, 0
            end
          end
        end

        should "create the table schema" do
          @db.define_class('TableSchema')
          @captured_schema.table_names.each do |table_name|
            @db.with_destination(table_name, true) do
              assert TableSchema.table_exists?, "TableSchema table does not exist in #{table_name}"
              assert_operator TableSchema.count, :>, 0
            end
          end
        end

        should "store the schema for each table" do
          @captured_schema.table_names.each do |table_name|
            @db.with_destination(table_name, true) do
              table_schema = TableSchema.find(:first, :conditions => {:table_name => table_name})
              assert table_schema, "Missing table schema for #{table_name}"
              assert_equal @captured_schema.schema_for(table_name), table_schema.schema
            end
          end
        end

      end


    end



  end

  context "class" do
    context "instance" do
      should "return a new instance" do
        assert ARDatabaseDuplicator.instance.is_a?(ARDatabaseDuplicator)
      end

      should "return the same instance" do
        first = ARDatabaseDuplicator.instance
        assert first.equal?(ARDatabaseDuplicator.instance)
      end

    end

    context "reset" do
      should "cause instance to return a new instance" do
        first = ARDatabaseDuplicator.instance
        ARDatabaseDuplicator.reset!
        assert !first.equal?(ARDatabaseDuplicator.instance)
      end
    end

  end

end

class VettedRecordTest < Test::Unit::TestCase
  context "class" do
    context "field_vetting" do
      setup do
        TestClass.instance_variable_set(:@field_vetting, nil)
      end

      should "default to true when created" do
        assert TestClass.field_vetting
      end

      should "default to true if set to nil" do
        TestClass.field_vetting = nil
        assert TestClass.field_vetting
      end

      should "remain false when set to false" do
        TestClass.field_vetting = false
        assert !TestClass.field_vetting
      end
    end

    context "safe_attributes" do
      setup do
        TestClass.instance_variable_set(:@safe_attributes, nil)
      end

      should "default to empty array" do
        assert TestClass.safe_attributes.blank?
      end

      should "be able to add to safe_attributes" do
        TestClass.mark_attribute_safe("safe")
        assert_equal ["safe"], TestClass.safe_attributes
      end

      should "not allow duplicates" do
        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_safe("safe")
        assert_equal ["safe"], TestClass.safe_attributes
      end
    end

    context "temporary_safe_attributes" do
      setup do
        TestClass.clear_temporary_safe_attributes
      end

      should "clear temp safe attributes" do
        TestClass.mark_attribute_temporarily_safe("new_one")
        TestClass.clear_temporary_safe_attributes
        assert TestClass.temporary_safe_attributes.blank?
      end

      should "default to empty array" do
        assert TestClass.temporary_safe_attributes.blank?
      end

      should "be able to add to safe_attributes" do
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal ["temp_safe"], TestClass.temporary_safe_attributes
      end

      should "not allow duplicates" do
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal ["temp_safe"], TestClass.temporary_safe_attributes
      end

    end

    context "vetted attributes" do
      setup do
        TestClass.instance_variable_set(:@safe_attributes, nil)
        TestClass.clear_temporary_safe_attributes
      end

      should "return column_names if field_vetting false" do
        TestClass.field_vetting = false

        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal TestClass::COLUMN_NAMES, TestClass.vetted_attributes
      end

      should "return only vetted attributes if field_vetting true" do
        TestClass.field_vetting = true

        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal ["safe", "temp_safe"], TestClass.vetted_attributes
      end

    end

    context "unvetted_attributes" do
      setup do
        TestClass.instance_variable_set(:@safe_attributes, nil)
        TestClass.clear_temporary_safe_attributes
      end

      should "return a blank array if field_vetting false" do
        TestClass.field_vetting = false

        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal [], TestClass.unvetted_attributes
      end

      should "return only unvetted attributes if field_vetting true" do
        TestClass.field_vetting = true

        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        assert_equal ["unsafe", "instance_safe", "changed"], TestClass.unvetted_attributes
      end

    end
  end

  context "instance" do
    context "vetted attributes" do
      setup do
        @ar_class = TestClass.new
      end

      should "default to empty array " do
        assert @ar_class.vetted_attributes.blank?
      end

      should "be able to add" do
        @ar_class.vet_attribute("instance_safe")
        assert_equal ["instance_safe"], @ar_class.vetted_attributes
      end

      should "not add duplicates"  do
        @ar_class.vet_attribute("instance_safe")
        @ar_class.vet_attribute("instance_safe")
        assert_equal ["instance_safe"], @ar_class.vetted_attributes
      end
    end

    context "unvetted attributes" do

      setup do
        @ar_class = TestClass.new
      end

      should "return unvetted attributes" do
        TestClass.mark_attribute_safe("safe")
        TestClass.mark_attribute_temporarily_safe("temp_safe")
        @ar_class.vet_attribute("instance_safe")
        @ar_class.stubs(:changed_attributes).returns({"changed" => "changed"})
        assert_equal ["unsafe"], @ar_class.unvetted_attributes
      end

    end

    context "vetted_save" do
      setup do
        @ar_class = TestClass.new
        @ar_class.stubs(:save_without_validation)
      end

      should "raise an exception if any of the attributes is not vetted" do
        TestClass.field_vetting = true
        assert_raises(ActiveRecord::VettedRecord::UnvettedAttribute) do
          @ar_class.vetted_save
        end
      end

      should "call save_without_validation if all attributes are vetted" do
        @ar_class.expects(:save_without_validation).once
        TestClass.field_vetting = false
        @ar_class.vetted_save
      end
    end
  end
end

