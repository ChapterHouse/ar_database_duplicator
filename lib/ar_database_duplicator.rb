require "active_record"
require 'pseudo_entity'
require 'ruby-progressbar'
require 'forwardable'
require 'encryptor'

module ActiveRecord

  module VettedRecord

    class UnvettedAttribute < Exception
    end

    def self.included(base)
      class << base
        attr_accessor :field_vetting

        def field_vetting
          @field_vetting.nil? ? @field_vetting = true : @field_vetting
        end

        def mark_attribute_safe(name)
          safe_attributes << name.to_s
          safe_attributes.uniq!
        end

        def mark_attribute_temporarily_safe(name)
          temporary_safe_attributes << name.to_s
          temporary_safe_attributes.uniq!
        end

        def safe_attributes
          @safe_attributes ||= []
        end

        # These are attributes that are to be considered safe at the class level but only for a specific period of time.
        def temporary_safe_attributes
          @temporary_safe_attributes ||= []
        end

        def clear_temporary_safe_attributes
          @temporary_safe_attributes = nil
        end

        # An array of attributes not already vetted at the class level
        def unvetted_attributes
          column_names - vetted_attributes
        end

        # An array of attributes already vetted at the class level
        def vetted_attributes
          field_vetting ? (safe_attributes + temporary_safe_attributes) : column_names
        end

        def with_field_vetting(&block)
          old_state = field_vetting
          begin
            self.field_vetting = true
            yield
          ensure
            self.field_vetting = old_state
          end
        end

        def without_field_vetting(&block)
          old_state = field_vetting
          begin
            self.field_vetting = false
            yield
          ensure
            self.field_vetting = old_state
          end
        end

      end
    end

    def unvetted_attributes
      # Start with all attributes not vetted at the class level.
      # Remove any attributes that were unchanged but marked as safe
      # Remove any attributes that were changed
      # And what you have left is unvetted attributes. Most likely a new field was added or a value was not given for an existing one.
      self.class.unvetted_attributes - vetted_attributes - changed_attributes.keys
    end

    def vetted?
      unvetted_attributes.empty?
    end

    # If an attribute for this instance is to be considered safe without being overwritten, mark it as vetted.
    def vet_attribute(name)
      vetted_attributes << name.to_s
      vetted_attributes.uniq!
    end

    def vetted_attributes
      @vetted_attributes ||= []
    end

    # This will only save if there are no unvetted attributes.
    def vetted_save
      raise UnvettedAttribute, "The following field(s) were not checked: #{unvetted_attributes.join(', ')}" unless vetted?
      save_without_validation
    end

  end

  class Base
    include VettedRecord
  end

end


class ARDatabaseDuplicator

  # Allow this class to be used as a singleton without absolutely enforcing it.
  extend SingleForwardable
  def_delegators :instance, :source, :source=, :destination, :destination=, :schema_file, :schema_file=, :force, :force=, :silent, :silent=, :test, :test=, :split_data, :split_data=,
                 :use_source, :use_destination, :load_schema, :duplicate, :while_silent, :while_not_silent, :define_class


  attr_accessor :source, :destination, :schema_file, :force, :silent, :test, :split_data

  def initialize(options={})
    @source = options[:source] || 'development'
    @destination = options[:destination] || 'dev_data'
    @schema_file = options[:schema_file] || 'db/schema.rb'
    @force = options.fetch(:force) { false }
    @test = options.fetch(:test) { false }
    @split_data = options.fetch(:split_data) { true }
  end

  def use_source(subname=nil)
    use_connection source, subname
  end

  def use_destination(subname=nil)
    use_connection destination, subname
  end

  def destination=(new_value)
    raise ArgumentError, "Production is not an allowed duplication destination." if new_value.downcase == "production"
    @destination_directory_exists = false
    @destination = new_value
  end

  def split_data=(new_value)
    @destination_directory_exists = false
    @split_data = new_value
  end

  def load_duplication(klass)
    raise ArgumentError, "Production must be duplicated, not loaded from." if source.downcase == "production"
    klass = define_class(klass) unless klass.is_a?(Class)
    records = with_source(klass) { klass.all }
    puts "#{records.size} #{plural(klass)} read."
    klass.without_field_vetting { transfer(klass, records) }
  end

  def load_schema
    # Adding this class just so we can check if a schema has already been loaded
    Object.const_set(:SchemaMigration, Class.new(ActiveRecord::Base)) unless Object.const_defined?(:SchemaMigration)
    split_data ? load_schema_split : load_schema_combined
  end

  def define_class(name)
    name = name.camelize.to_sym
    Object.const_set(name, Class.new(ActiveRecord::Base)) unless Object.const_defined?(name)
    Object.const_get(name)
  end

  # Duplicate each record, via ActiveRecord, from the source to the destination database.
  # Field replacements can be given via a hash in the form of :original_field => :pseudo_person_field
  # If a block is passed, the record will be passed for inspection/alteration before
  # it is saved into the destination database.
  def duplicate(klass, replacements={}, *additional_replacements, &block)
    klass = define_class(klass) unless klass.is_a?(Class)

    plural = plural(klass)

    automatic_replacements = [replacements] + additional_replacements
    raise(ArgumentError, "Each group of replacements must be given as a Hash") unless automatic_replacements.all? { |x| x.is_a?(Hash) }

    sti_klasses = []
    set_temporary_vetted_attributes(klass, automatic_replacements)

    # If we aren't guaranteed to fail on vetting
    if block_given? || !block_required?(klass)
      # If we have potential duplication to do
      if force || !already_duplicated?(klass)
        # Connect to the source database
        with_source do
          # Grab a quick count to see if there is anything we need to do.
          estimated_total = klass.count
          if estimated_total > 0
            inform(test ? "Extracting first 1,000 #{plural} for testing" : "Extracting all #{plural}")
            # Pull in all records. Perhaps later we can enhance this to do it in batches.
            unless singleton?(klass)
              records = test ? klass.find(:all, :limit => 1000) : klass.find(:all)
            else
              records = [klass.instance]
            end

            # Handle any single table inheritance that may have shown up
            records.map(&:class).uniq.each { |k| sti_klasses << k if k != klass }
            sti_klasses.each { |k| set_temporary_vetted_attributes(k, automatic_replacements) }

            # Record the size so we can give some progress indication.
            inform "#{records.size} #{plural} read"

            transfer(klass, records, automatic_replacements, &block)
          else
            inform "Skipping #{plural}. No records exist."
          end
        end
      else
        inform "Skipping #{plural}. Records already exist."
      end
    else
      inform "Skipping #{plural}. The following field(s) were not checked: #{klass.unvetted_attributes.join(', ')}"
    end

    # Clean things up for the next bit of code that might use this class.
    klass.clear_temporary_safe_attributes
    sti_klasses.each { |k| k.clear_temporary_safe_attributes }
  end

  def while_silent(&block)
    with_silence_at(true, &block)
  end

  def while_not_silent(&block)
    with_silence_at(false, &block)
  end

  def with_source(subname=nil, silent_change=false, &block)
    with_connection(source, subname, silent_change, &block)
  end

  def with_destination(subname=nil, silent_change=false, &block)
    with_connection(destination, subname, silent_change, &block)
  end

  # With a specified connection, connect, execute a block, then restore the connection to it's previous state (if any).
  def with_connection(name, subname=nil, silent_change=false, &block)
    old_connection = connection
    begin
      use_connection(name, subname, silent_change)
      result = yield
    ensure
      use_spec(old_connection)
    end
    result
  end

  def self.instance(options={})
    options[:source] ||= 'development'
    options[:destination] ||= 'dev_data'
    options[:schema] ||= 'db/schema.rb'
    options[:force] = false unless options.has_key?(:force)
    options[:test] = true unless options.has_key?(:test)
    options[:split_data] = true unless options.has_key?(:split_data)
    @duplicator ||= new(options)
  end

  def self.reset!
    @duplicator = nil
  end

  private

  def base_path
    @base_path ||= Rails.root + "db" + "duplication"
  end

  def destination_directory_exists?
    @destination_directory_exists
  end

  def destination_directory
    split_data ? base_path + destination : base_path
  end

  def connection
    @connection
  end

  def connection=(new_name)
    @connection = new_name
  end

  def connected_to?(name)
    connection == name
  end

  def create_destination_directory
    destination_directory.mkpath unless destination_directory.exist?
    @destination_directory_exists = true
  end


  def entity
    @entity ||= PseudoEntity.new
  end

  def inform(message)
    puts message unless silent
  end

  # Load the schema into the destination database
  def load_schema_combined
    with_destination do
      # If there is no schema or we are forcing things
      if !schema_loaded?
        captured_schema = CapturedSchema.new(self, schema_file)

        # sqlite3 handles index names at the database level and not at the table level.
        # This can cause issues with adding indexes. Since we wont be depending on them anyway
        # we will just stub this out so we can load the schema without issues.
        #schema_klass = ActiveRecord::Schema
        #
        #def schema_klass.add_index(*args)
        #  say_with_time "add_index(#{args.map(&:inspect).join(', ')})" do
        #    say "skipped", :subitem
        #  end
        #end
        load schema_file

        ActiveRecord::Schema.define(:version => captured_schema.recorded_assume_migrated[1]) do
          create_table "table_schemas", :force => true do |t|
            t.string "table_name"
            t.text "schema"
          end
        end
        captured_schema.table_names.each do |table_name|
          TableSchema.create(:table_name => table_name, :schema => captured_schema.schema_for(table_name))
        end
      else
        inform 'Skipping schema load. Schema already loaded.'
      end
    end
  end

# Load the schema into the separate destination databases. Each db corresponds to one table.
  def load_schema_split
    captured_schema = CapturedSchema.new(self, schema_file)
    no_schema_loaded = true

    # Now that we know all of the tables, indexes, etc we are ready to split things up into multiple databases for easy transport.
    captured_schema.table_names.sort.each do |table_name|
      if !schema_loaded?(table_name)
        no_schema_loaded = false
        with_destination(table_name) do
          commands = captured_schema.table_commands_for(table_name)

          ActiveRecord::Schema.define(:version => captured_schema.recorded_assume_migrated[1]) do
            commands.each do |command|
              command = command.dup
              block = command.pop
              self.send(*command, &block)
            end
            create_table "table_schemas", :force => true do |t|
              t.string "table_name"
              t.text "schema"
            end

            command = captured_schema.recorded_initialize_schema.dup
            block = command.pop
            self.send(*command, &block) unless command.empty?

            command = captured_schema.recorded_assume_migrated.dup
            block = command.pop
            self.send(*command, &block) unless command.empty?
          end
          TableSchema.create(:table_name => table_name, :schema => captured_schema.schema_for(table_name))
        end
      end
    end

    inform 'Skipping schema load. Schema already loaded.' if no_schema_loaded

  end



  def replace_attributes(record, automatic_replacements, &block)

    # Do any automatic field replacements
    automatic_replacements.each do |replacement_hash|
      # For each hash, reset the pseudo entity and the use it to do replacements.
      entity.reset!
      replace(record, replacement_hash) unless replacement_hash.empty?
    end

    # Before we save it, pass the newly cloned record to a block for inspection/alteration
    if block_given?
      block_replacements =
          # If the block only wants the record send it in.
          if block.arity == 1
            yield(entity.reset!)
          else
            # Otherwise send in a PseudoEntity with the made up data to be used for field replacement.
            yield(entity.reset!, record)
          end
      replace(record, block_replacements) unless !block_replacements.is_a?(Hash) || block_replacements.empty?
    end

  end

  # Replace each value in the target if it is already populated.
  def replace(target, hash)
    hash.each do |key, value_key|
      # We either have a symbol representing a method to call on PseudoEntity or a straight value.
      value = value_key
      # In general we aren't dealing with encrypted data.
      encrypted = false
      # If this is a command we are call to get the value
      if value_key.is_a?(Symbol)
        # If we are replacing an encrypted field
        if value_key.to_s.start_with?('encrypted_')
          encrypted = true
          # Change the command to be the non encrypted version so we can get the actual value.
          value_key = value_key.to_s[10..-1].to_sym
        end
        # Throw an error if we do not recognize the PseudoEntity method
        raise "No replacement defined for #{value_key.inspect}" unless entity.respond_to?(value_key)
        # Grab the actual value we will use for replacement
        value = entity.send(value_key)
      end

      # If the value is to be encrypted
      if encrypted
        salt_method = "#{key}_salt".to_sym
        iv_method = "#{key}_iv".to_sym
        # If the record has an existing salt then replace it
        if target.respond_to?(salt_method) && !target.send(salt_method).blank?
          salt = entity.reset('salt')
          replace_with(target, salt_method, salt)
        else
          salt = nil
        end

        # If the record has an existing iv then replace it
        if target.respond_to?(iv_method) && !target.send(iv_method).blank?
          iv = entity.reset('iv')
          replace_with(target, iv_method, iv)
        else
          iv = nil
        end

        # Use the same combination as I use on my luggage. No one will ever guess that.
        value = value.encrypt(:key => "1234", :salt => salt, :iv => iv)
      end
      replace_with target, key, value
    end
  end

  # Replace a value in the target if it is already populated.
  def replace_with(target, key, value)
    if value.is_a?(Proc)
      value =
          case value.arity
          when 0
            value.call
          when 1
            value.call(entity)
          when 2
            value.call(entity, target)
          else
            value.call(entity, target, key)
          end
    end
    target.send("#{key}=", value) unless target.send(key).blank?
    target.vet_attribute(key) if target.respond_to?(:vet_attribute)
  end

  def salt
    entity.class.new.salt
  end


  def set_temporary_vetted_attributes(klass, automatic_replacements)

    # Reset the class to its normal safe attributes. We will not trust that this has been done for us before. Even if we were the last ones to touch this class.
    klass.clear_temporary_safe_attributes
    # Duplication considers the following fields always safe and won't be modifying them.
    klass.mark_attribute_temporarily_safe(:id)
    klass.mark_attribute_temporarily_safe(:created_at)
    klass.mark_attribute_temporarily_safe(:updated_at)
    klass.mark_attribute_temporarily_safe(:deleted_at)
    klass.mark_attribute_temporarily_safe(:lock_version)
    # Take each attributes that we will attempt to automatically replace
    automatic_replacements.each do |replacement_set|
      replacement_set.each do |attr, value|
        # Mark it temporarily safe at the class level.
        # This allows an attribute to be considered vetted if any instance has a nil value and no substitution is performed.
        klass.mark_attribute_temporarily_safe(attr)
        # If PseudoEntity will be using an encrypted version of its attribute
        if value.is_a?(Symbol) && value.to_s.starts_with?("encrypted_")
          # Then it will automatically attempt to populate the salt and iv fields as well. So we can clear those.
          klass.mark_attribute_temporarily_safe "#{attr}_salt"
          klass.mark_attribute_temporarily_safe "#{attr}_iv"
        end
      end
    end

  end

  def transfer(klass, records, automatic_replacements={}, &block)
    plural = plural(klass)
    inform "Transferring #{plural}"

    # Switch to the destination database
    with_destination(klass) do
      problematic_records = []
      # Blow away all callbacks. We are looking at a pure data transfer here.
      clear_callbacks(klass)

      progress_bar = ProgressBar.create(:title => title_plural(klass), :total => records.size, :format => '%t %p%% [%b>>%i] %c/%C %E ', :smoothing => 0.9)
      # Take each record, replace any data required, and save
      records.each do |record|
        replace_attributes(record, automatic_replacements, &block)

        # Trick active record into saving this record all over again in its entirety
        record.instance_variable_set(:@new_record, true)

        # Save without validation as there is no guaranteed order of how the classes will be duplicated. We don't want to trigger any callbacks referencing other tables.
        # Besides, they should have already been validated when they were saved in production.
        begin
          record.vetted_save
        rescue ActiveRecord::StatementInvalid => e
          inform "Problems saving record #{record.id}."
          inform e.message
          inform "Adding record to emergency yaml dump"
          problematic_records << record
        rescue ActiveRecord::VettedRecord::UnvettedAttribute => e
          inform "#{record.class.name}##{record.id} not duplicated for security reasons"
          inform e.message
        rescue => e
          puts "Not good! I just got an #{e.inspect}"
          # Quick cleanup
          klass.clear_temporary_safe_attributes
          sti_klasses.each { |k| k.clear_temporary_safe_attributes }
          raise e
        end
        # Give an update of the percentage transferred
        progress_bar.increment
      end

      unless problematic_records.blank?
        file_name = "#{destination}.#{klass.name}.yaml"
        inform "Saving #{problematic_records.size} #{plural} to #{file_name}"
        # TODO: Change to deal with split data
        File.open( file_name, 'w' ) { |out| YAML.dump(problematic_records, out) }
      end

    end

    inform "All #{plural} transferred"

  end

  def title_plural(klass)
    klass.name.titleize.pluralize
  end

  def plural(klass)
    title_plural(klass).downcase
  end

  def with_silence_at(value)
    saved_setting = silent
    self.silent = value
    begin
      yield
    ensure
      @silent = saved_setting
    end
  end

  def already_duplicated?(klass)
    with_destination(klass, true) do
      singleton?(klass) ? klass.count > 0 : !klass.first.nil?
    end
  end

  def schema_loaded?(subname=nil)
    if force
      false
    else
      define_class('SchemaMigration')
      with_destination(subname, true) { SchemaMigration.table_exists? && SchemaMigration.count > 0 }
    end
  end

  def singleton?(klass)
    klass.included_modules.map(&:to_s).include?('ActiveRecord::Singleton')
  end

  # Hopefully this will be rails version agnostic. But knowing my luck... Oh well.
  def clear_callbacks(klass)
    callbacks = [:after_initialize, :after_find, :after_touch, :before_validation, :after_validation, :before_save, :around_save, :after_save,
                 :before_create, :around_create, :after_create, :before_update, :around_update, :after_update, :before_destroy, :around_destroy,
                 :after_destroy, :after_commit, :after_rollback
    ]

    callbacks.each do |callback|
      begin
        klass.send(callback).clear
      rescue NoMethodError
      end
    end


  end

  # Returns true if we absolutely know that a block will be required for vetting to pass
  def block_required?(klass)
    with_source(nil, true) { !klass.unvetted_attributes.empty? }
  end

  def use_connection(name, subname=nil, silent_change=false)
    # If this is a connection defined in the database.yml
    if ActiveRecord::Base.configurations.keys.include?(name)
      # The database spec is the same as the name
      spec = name
    else # Otherwise we are going to use a sqlite3 database specified at runtime
         # Convert from a class to the table name if needed.
      subname = subname.table_name if subname.is_a?(Class) && subname < ActiveRecord::Base
      # Start with the location the sqlite data will be
      database = destination_directory
      # If we are splitting the data into individual tables
      if split_data
        # Add the subname to the path if one is given
        unless subname.blank?
          database += subname
        else
          # Move up one directory level and add a sqlite3 extension to avoid name collision.
          database = database.parent + "#{destination}.sqlite3"
        end
      else
        # Add a sqlite3 extension to avoid name collisions.
        database += "#{destination}.sqlite3"
      end

      # Create the database spec
      spec = {:adapter => 'sqlite3',:database => database.to_s, :host => 'localhost', :username => 'root'}
      # Set the name to something nice for display
      name = database.basename(database.extname)
    end

    use_spec(spec, silent_change ? nil : name)

  end

  def use_spec(spec, name=nil)
    # If we aren't already connected to the database
    unless connected_to?(spec)
      # Create the directory structure if needed
      create_destination_directory if spec.is_a?(Hash) && (spec[:adapter] == 'sqlite3') && !destination_directory_exists?
      # Give a heads up on  the switch
      inform "Switching to #{name}" if name
      # Disconnect any existing connections
      ActiveRecord::Base.clear_active_connections! if connection
      # Make the connection if we were given a new one
      ActiveRecord::Base.establish_connection(spec) if spec
      # Remember where we are connected to so we don't do it again if it isn't necessary
      self.connection = spec
    end
  end

end

class ARDatabaseDuplicator::CapturedSchema

  attr_reader :schema, :db, :schema_file_name

  def initialize(ardb, schema_file_name)
    @db = ardb
    self.schema_file_name = schema_file_name
    parse_schema
  end

  def table_commands_for(table_name)
    recorded_table_commands[table_name]
  end

  def schema_for(table_name)
    [create_table_command(table_name), index_commands(table_name)].join("\n")
  end

  def table_names
    recorded_table_commands.keys
  end

  def recorded_assume_migrated
    @recorded_assume_migrated ||= []
  end

  def recorded_initialize_schema
    @recorded_initialize_schema ||= []
  end

  private

  def schema=(x)
    @schema = x
  end

  def schema_file_name=(x)
    @schema_file_name = x
  end

  def create_table_command(table_name)
    create_command = recorded_table_commands[table_name].find { |x| x.first == :create_table }
    if create_command
      (["create_table #{create_command[0..-2].map(&:inspect).join(', ')} do |t|"] + recorded_table_columns[table_name] + ['end']).join("\n")
    else
      ''
    end
  end

  def index_commands(table_name)
    recorded_table_commands[table_name].find_all { |x| x.first == :add_index }.inject([]) do |commands, command|
      commands << "add_index " + command[1..-2].map(&:inspect).join(', ')
    end.join("\n")
  end

  def recorded_table_commands
    @recorded_table_commands ||= Hash.new { |hash, key| hash[key] = [] }
  end

  def recorded_table_columns
    @recorded_table_columns ||= Hash.new
  end



  def parse_schema
    self.schema = File.read(schema_file_name)

    # Create the two interceptors.
    # The first for the create table blocks to get the columns, the second for the create_table and add_index commands.

    # This is the column interceptor.
    table_definition = recording_table_definition
    table_commands = recorded_table_commands
    table_columns = recorded_table_columns
    assume_migrated = recorded_assume_migrated
    initialize_schema = recorded_initialize_schema
    # This interceptor helps us learn what tables we will be defining by intercepting the important schema commands.
    # Additionally determine the final assume_migrated_upto_version arguments.
    # These will be used for each sub database created.
    # The 1.8.x style of define_singleton_method
    schema_klass_singleton = class << ActiveRecord::Schema; self; end
    schema_klass_singleton.send(:define_method, :method_missing) do |name, *arguments, &block|
      if name.to_sym == :create_table
        # Pull out the table name
        table_name = arguments.first
        # Record the creation command
        table_commands[table_name] << ([name] + arguments + [block] )

        # Now lets get what is inside that block so we know what columns there are.
        # Start with no columns
        table_definition.column_commands = []
        # Call the block with our recorder (instead of a normal table definition instance)
        block.call(table_definition)
        # Save off all of the column commands
        table_columns[table_name] = table_definition.column_commands
      elsif name.to_sym == :add_index
        table_commands[arguments.first] << ([name] + arguments + [block] )
      elsif name.to_sym == :assume_migrated_upto_version
        assume_migrated.replace ([name] + arguments + [block] )
      elsif name.to_sym == :initialize_schema_migrations_table
        initialize_schema.replace ([name] + arguments + [block] )
      end
    end


    # Now with the above interceptors/recorders in place, eval the schema capture all of the data.
    # This is a safety thing. Just in case examining the schema causes a change
    # (which it never should) we don't want to touch our source.
    db.with_connection("schema_eval", nil, true) do
      eval(schema)
    end

    # Now to remove the interceptor/recorders defined above
    schema_klass_singleton.send(:remove_method, :method_missing)

  end

  def recording_table_definition
    unless @recording_table_definition
      @recording_table_definition = ActiveRecord::ConnectionAdapters::TableDefinition.new(nil)
      @recording_table_definition.instance_eval <<-EOV, __FILE__, __LINE__ + 1
        def column_commands
          @column_commands
        end

        def column_commands=(x)
          @column_commands = x
        end
      EOV

      %w( string text integer float decimal datetime timestamp time date binary boolean ).each do |column_type|
        @recording_table_definition.instance_eval <<-EOV, __FILE__, __LINE__ + 1
          def #{column_type}(*args)
            column_options = args.extract_options!
            column_names = args
            command_args = column_options.map { |x| x.map(&:inspect).join(' => ') }
            column_names.each do |name|
              column_commands << "  t.#{column_type} " + command_args.unshift(name.inspect).join(', ')
            end
          end
        EOV
      end
    end
    @recording_table_definition
  end


end


class ARDatabaseDuplicator::TableSchema < ActiveRecord::Base
  #self.table_name = "table_schema"
end



