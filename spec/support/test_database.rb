# frozen_string_literal: true

require "uri"
require "pg"
require "active_record"

# Real-PostgreSQL setup for the ActiveRecord specs. Requiring this file
# touches nothing: call .setup from a spec hook.
module DeckardTestDatabase
  URL = ENV.fetch("DECKARD_TEST_DATABASE_URL", "postgres://127.0.0.1:5433/deckard_gem_test")
  DESTINATION_URL = ENV.fetch("DECKARD_TEST_DESTINATION_DATABASE_URL") do
    uri = URI(URL)
    uri.path = "#{uri.path}_destination"
    uri.to_s
  end

  TABLES = %w[bookmarks comments payments profiles posts authors cycle_as cycle_bs
    reader_emails readers books libraries cargos ships employees artifacts
    itineraries].freeze

  class SourceRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  class DestinationRecord < ActiveRecord::Base
    self.abstract_class = true
  end

  # Connect, create the test database if missing, verify the server runs
  # PostgreSQL 18 (matching the e2e harness), and define the schema.
  # Memoized across calls; connection and setup failures propagate.
  def self.setup
    return if @setup

    connect_and_define_schema(URL)
    SourceRecord.establish_connection(URL)
    @setup = true
  end

  def self.setup_destination
    return if @destination_setup

    connect_and_define_schema(DESTINATION_URL)
    DestinationRecord.establish_connection(DESTINATION_URL)
    @destination_setup = true
  ensure
    ActiveRecord::Base.establish_connection(URL)
  end

  def self.with_destination
    ActiveRecord::Base.establish_connection(DESTINATION_URL)
    yield
  ensure
    ActiveRecord::Base.establish_connection(URL)
  end

  def self.truncate
    ActiveRecord::Base.connection.execute("TRUNCATE #{TABLES.join(", ")} RESTART IDENTITY")
  end

  def self.connect_and_define_schema(url)
    create_database(url)
    ActiveRecord::Base.establish_connection(url)
    check_server_version(url)
    configure_encryption
    define_schema
    nil
  end
  private_class_method :connect_and_define_schema

  def self.create_database(url)
    admin_uri = URI(url)
    database = admin_uri.path.delete_prefix("/")
    admin_uri.path = "/postgres"
    admin = PG.connect(admin_uri.to_s)
    if admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).ntuples.zero?
      admin.exec("CREATE DATABASE #{admin.quote_ident(database)}")
    end
    admin.close
  end
  private_class_method :create_database

  def self.check_server_version(url)
    version = ActiveRecord::Base.connection.select_value("SHOW server_version")
    unless version.start_with?("18.")
      raise "deckard specs must run against PostgreSQL 18 to match the e2e harness; " \
        "#{url} is running #{version}"
    end
  end
  private_class_method :check_server_version

  def self.configure_encryption
    ActiveRecord::Encryption.configure(
      primary_key: "deckard-test-primary-key",
      deterministic_key: "deckard-test-deterministic-key",
      key_derivation_salt: "deckard-test-salt"
    )
  end
  private_class_method :configure_encryption

  def self.define_schema
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      execute "DROP TYPE IF EXISTS artifact_mood CASCADE"
      create_enum :artifact_mood, %w[calm ominous]
      create_table :authors, force: :cascade do |t|
        t.string :name, null: false
        t.string :username
        t.string :email
        t.text :bio
        t.string :location
        t.string :website
        t.boolean :verified, null: false, default: false
        t.json :settings
        t.datetime :joined_at
        t.timestamps
      end

      create_table :profiles, force: :cascade do |t|
        t.references :author, null: false
        t.string :bio
      end

      create_table :posts, force: :cascade do |t|
        t.references :author, null: false
        t.string :title, null: false
        t.text :body
        t.string :description
        t.json :metadata
        t.string :visibility, null: false, default: "public"
        t.string :language
        t.boolean :sensitive, null: false, default: false
        t.datetime :published_at
      end

      create_table :comments, force: :cascade do |t|
        t.references :post, null: false
        t.references :author, null: false
        t.string :body
      end

      create_table :bookmarks, id: false, force: :cascade do |t|
        t.references :author, null: false
        t.references :post, null: false
      end

      create_table :payments, force: :cascade do |t|
        t.references :billable, polymorphic: true
        t.integer :amount
      end

      create_table :cycle_as, force: :cascade do |t|
        t.references :cycle_b
      end

      create_table :cycle_bs, force: :cascade do |t|
        t.references :cycle_a
      end

      create_table :readers, force: :cascade do |t|
        t.string :login, null: false
        t.string :email
      end

      create_table :reader_emails, force: :cascade do |t|
        t.references :reader, null: false
        t.string :email, null: false
        t.string :label
      end

      create_table :libraries, force: :cascade do |t|
        t.string :name, null: false
        t.string :secret
        t.string :type
      end

      create_table :books, force: :cascade do |t|
        t.references :library
        t.string :title, null: false
      end

      create_table :ships, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
        t.string :name, null: false
      end

      create_table :cargos, id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
        t.references :ship, type: :uuid, null: false
        t.string :contents, null: false
      end

      create_table :employees, force: :cascade do |t|
        t.string :name, null: false
        t.references :manager
      end

      create_table :artifacts, force: :cascade do |t|
        t.string :name, null: false
        t.jsonb :meta
        t.string :tags, array: true
        t.decimal :price, precision: 10, scale: 2
        t.boolean :active
        t.date :released_on
        t.datetime :measured_at, precision: 6
        t.binary :blob
        t.uuid :token
        t.integer :status, null: false, default: 0
        t.virtual :name_upper, type: :string, as: "upper(name)", stored: true
        t.enum :mood, enum_type: :artifact_mood
        t.text :notes
      end

      create_table :itineraries, primary_key: [:vehicle_id, :leg], force: :cascade do |t|
        t.integer :vehicle_id, null: false
        t.integer :leg, null: false
        t.string :note
      end
    end
  end
  private_class_method :define_schema
end
