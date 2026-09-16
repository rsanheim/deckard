# frozen_string_literal: true

require_relative "lib/deckard/version"

Gem::Specification.new do |spec|
  spec.name = "deckard"
  spec.version = Deckard::VERSION
  spec.authors = ["Rob Sanheim"]
  spec.email = ["rsanheim@gmail.com"]
  spec.license = "MIT"

  spec.summary = "Stream ActiveRecord objects between Rails environments"
  spec.description = "Copy selected ActiveRecord records and their associations between " \
    "PostgreSQL databases, with destination-generated primary keys, remapped " \
    "foreign keys, and transactional loads."
  spec.homepage = "https://github.com/rsanheim/deckard"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rsanheim/deckard/tree/main"

  # Ship only the library, executable, and top-level docs. A plain glob (not
  # `git ls-files`) so the gem also resolves as a path dependency in contexts
  # without a .git directory, such as the harness docker image.
  spec.files = Dir.glob(%w[lib/**/*.rb exe/* README.md LICENSE.txt], base: __dir__)
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.0", "< 9.0"
  spec.add_dependency "optimist", "~> 3.2"
end
