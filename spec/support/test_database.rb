# frozen_string_literal: true

require "uri"
require "pg"
require "active_record"

# Real-PostgreSQL setup for the ActiveRecord specs. Requiring this file
# touches nothing: call .setup from a spec hook.
module DeckardTestDatabase
  URL = ENV.fetch("DECKARD_TEST_DATABASE_URL", "postgres://127.0.0.1:5433/deckard_gem_test")

  TABLES = %w[comments payments profiles posts authors cycle_as cycle_bs].freeze

  # Connect, create the test database if missing, verify the server runs
  # PostgreSQL 18 (matching the e2e harness), and define the schema.
  # Memoized across calls; returns nil when ready, or an error description
  # when no server is reachable. A reachable server on the wrong major
  # version raises instead of skipping.
  def self.setup
    return @setup_error if defined?(@setup_error)
    @setup_error = connect_and_define_schema
  end

  def self.truncate
    ActiveRecord::Base.connection.execute("TRUNCATE #{TABLES.join(", ")} RESTART IDENTITY")
  end

  def self.connect_and_define_schema
    create_database
    ActiveRecord::Base.establish_connection(URL)
    check_server_version
    define_schema
    nil
  rescue PG::Error, ActiveRecord::ConnectionNotEstablished => e
    "#{e.class}: #{e.message.strip.lines.first}"
  end
  private_class_method :connect_and_define_schema

  def self.create_database
    admin_uri = URI(URL)
    database = admin_uri.path.delete_prefix("/")
    admin_uri.path = "/postgres"
    admin = PG.connect(admin_uri.to_s)
    if admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [database]).ntuples.zero?
      admin.exec("CREATE DATABASE #{admin.quote_ident(database)}")
    end
    admin.close
  end
  private_class_method :create_database

  def self.check_server_version
    version = ActiveRecord::Base.connection.select_value("SHOW server_version")
    unless version.start_with?("18.")
      raise "deckard specs must run against PostgreSQL 18 to match the e2e harness; " \
        "#{URL} is running #{version}"
    end
  end
  private_class_method :check_server_version

  def self.define_schema
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :authors, force: :cascade do |t|
        t.string :name, null: false
        t.timestamps
      end

      create_table :profiles, force: :cascade do |t|
        t.references :author, null: false
        t.string :bio
      end

      create_table :posts, force: :cascade do |t|
        t.references :author, null: false
        t.string :title, null: false
      end

      create_table :comments, force: :cascade do |t|
        t.references :post, null: false
        t.references :author, null: false
        t.string :body
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
    end
  end
  private_class_method :define_schema
end
